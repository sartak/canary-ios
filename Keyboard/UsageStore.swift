//
//  UsageStore.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics
import Foundation
import SQLite3

/// Kinds of tap-typing correction signal we log (swiping.md §9, PLAN.md M9).
enum TapEventKind: String {
    case autocorrectApplied = "autocorrect_applied"
    case autocorrectRejected = "autocorrect_rejected"
    case suggestionPicked = "suggestion_picked"
}

/// Every tunable constant for word learning + personal frequency, in one place
/// (mirrors `SwipeTuning`'s doc style). See PLAN.md Milestone 9 / swiping.md §9.
enum LearningTuning {
    /// Committed-usage count at which an out-of-lexicon word is promoted to the
    /// learned set. Three plain uses (or one autocorrect rejection, which skips
    /// the threshold entirely) makes a word first-class.
    static let promotionThreshold = 3

    /// Corpus-count equivalent given to an out-of-lexicon learned word so it can
    /// compete in the swipe prior against real vocabulary. ~= a solidly common
    /// word ('keyboard' is ~21M in the Google Web Trillion Word Corpus).
    static let learnedWordFrequency = 10_000_000

    /// Occurrence mass added to the swipe prior's effective count per personal
    /// use of a word: one use ≈ 'keyboard'-level frequency, enough to break a
    /// geometric tie toward the user's actual vocabulary (swipe→scope, canary).
    static let personalCountBoost = 20_000_000
}

/// Local, append-only usage/correction log for both swipe and tap typing.
///
/// PLAN.md Milestone 9 nominally calls for Core Data; we deliberately use raw
/// SQLite instead. It matches every other persistence surface in this codebase
/// (`SwipeLexicon`, `SuggestionService`, the bundled `words.db`) and avoids
/// standing up a Core Data stack inside a memory-capped keyboard extension.
///
/// This store owns its OWN database (`usage.db`) — never `words.db`, which ships
/// read-only in the app bundle. A keyboard extension *without* Full Access can
/// still read and write its own sandbox container, so no `RequestsOpenAccess` is
/// needed here. Only sharing this data with the containing app (a future
/// dictionary-management UI) would require an App Group; that is out of scope now.
///
/// Everything is best-effort and must never take typing down: the initializer is
/// failable, the database is opened lazily on the first write (cold-start latency
/// matters), and every method silently no-ops on any error, printing a one-line
/// diagnostic in the house style rather than asserting or crashing.
///
/// This milestone is logging only — no typing behavior changes based on the data.
final class UsageStore {
    private let dbURL: URL
    private var db: OpaquePointer?
    /// Latches once opening fails so we don't retry the open on every keystroke.
    private var openFailed = false

    private static let swipeCorrectionCap = 2000
    private static let tapEventCap = 5000

    /// Personal usage counts keyed by lowercased word, loaded once from
    /// `word_usage` on first access and kept in sync by `bumpWordUsage`. The
    /// keyboard is single-threaded UI, so no locking is needed. `nil` = not yet
    /// loaded (distinct from loaded-and-empty).
    private var personalCounts: [String: Int]?
    /// Learned words keyed by lowercased word → last-seen original casing,
    /// loaded once from `learned_words` and kept in sync by `markLearned`.
    private var learned: [String: String]?
    /// iOS-provided words for this session (UILexicon), lowercased → provided
    /// casing. In-memory only; see setExternalWords.
    private var externalWords: [String: String] = [:]

    /// Upper bound on session words accepted from UILexicon.
    private static let externalWordCap = 2000

    /// Resolves the on-disk path; does NOT open the database yet.
    init?() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else {
            print("UsageStore: could not resolve application support directory")
            return nil
        }
        self.dbURL = support.appendingPathComponent("usage.db")
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Increment the lifetime swipe-commit counter (denominator for correction rate).
    func recordSwipeCommit() {
        guard let db = connection() else { return }
        exec(db, """
            INSERT INTO counters (name, value) VALUES ('swipe_commits', 1)
            ON CONFLICT(name) DO UPDATE SET value = value + 1
            """)
        print("UsageStore: swipe commit")
    }

    /// A swiped word was replaced by the user via a suggestion-bar tap.
    func recordSwipeCorrection(path: [CGPoint], committed: String, corrected: String,
                               ranked: [String], layout: String,
                               keyboardSize: CGSize, keyPitch: CGFloat) {
        guard let db = connection() else { return }

        let pathString = path.map { String(format: "%.1f,%.1f", $0.x, $0.y) }.joined(separator: ";")
        let rankedJSON = jsonArray(ranked)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO swipe_corrections
            (created_at, layout, keyboard_width, keyboard_height, key_pitch, committed, corrected, ranked, path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare swipe correction insert")
            return
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, layout, -1, transient)
        sqlite3_bind_double(statement, 3, Double(keyboardSize.width))
        sqlite3_bind_double(statement, 4, Double(keyboardSize.height))
        sqlite3_bind_double(statement, 5, Double(keyPitch))
        sqlite3_bind_text(statement, 6, committed, -1, transient)
        sqlite3_bind_text(statement, 7, corrected, -1, transient)
        sqlite3_bind_text(statement, 8, rankedJSON, -1, transient)
        sqlite3_bind_text(statement, 9, pathString, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: swipe correction insert failed")
            return
        }
        trim(db, table: "swipe_corrections", cap: Self.swipeCorrectionCap)
        print("UsageStore: swipe correction '\(committed)' -> '\(corrected)' (path \(path.count) pts)")
    }

    /// A tap-typing correction signal: autocorrect applied/rejected, or a
    /// typeahead suggestion picked.
    func recordTapEvent(kind: TapEventKind, typed: String, resolved: String) {
        guard let db = connection() else { return }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO tap_events (created_at, kind, typed, resolved) VALUES (?, ?, ?, ?)
            """, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare tap event insert")
            return
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 3, typed, -1, transient)
        sqlite3_bind_text(statement, 4, resolved, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: tap event insert failed")
            return
        }
        trim(db, table: "tap_events", cap: Self.tapEventCap)
        print("UsageStore: tap \(kind.rawValue) '\(typed)' -> '\(resolved)'")
    }

    // MARK: - Word usage + learned words (Milestone 9 stage 2)

    /// Records one committed use of `word`, incrementing its lifetime personal
    /// count. `trustCasing` controls whether this use also refreshes the stored
    /// casing: sentence-initial commits pass false because auto-shift
    /// capitalization is noise, not evidence of how the user cases the word
    /// (mid-sentence "Claude" is deliberate; sentence-start "The" is not).
    /// Returns the new count, or 0 on a hygiene-guard rejection or any store
    /// failure. Intentionally quiet — this fires once per committed word;
    /// only promotions and learned-casing changes print.
    @discardableResult
    func bumpWordUsage(_ word: String, trustCasing: Bool = true) -> Int {
        guard Self.isLearnableWord(word), let db = connection() else { return 0 }
        let lower = word.lowercased()

        let sql = trustCasing
            ? """
              INSERT INTO word_usage (word_lower, word, count, last_used) VALUES (?, ?, 1, ?)
              ON CONFLICT(word_lower) DO UPDATE SET
                  count = count + 1, word = excluded.word, last_used = excluded.last_used
              """
            : """
              INSERT INTO word_usage (word_lower, word, count, last_used) VALUES (?, ?, 1, ?)
              ON CONFLICT(word_lower) DO UPDATE SET
                  count = count + 1, last_used = excluded.last_used
              """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare word usage upsert")
            return 0
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, word, -1, transient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: word usage upsert failed")
            return 0
        }

        let newCount = (loadPersonalCounts()[lower] ?? 0) + 1
        personalCounts?[lower] = newCount
        if trustCasing {
            refreshLearnedCasing(word, lower: lower)
        }
        return newCount
    }

    /// Propagates a trusted casing change to the learned set, so a word learned
    /// as "claude" upgrades to "Claude" once the user cases it that way
    /// mid-sentence (and can downgrade again if they stop).
    private func refreshLearnedCasing(_ word: String, lower: String) {
        guard let stored = loadLearned()[lower], stored != word, let db = connection() else { return }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE learned_words SET word = ? WHERE word_lower = ?",
                                 -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare learned casing update")
            return
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, word, -1, transient)
        sqlite3_bind_text(statement, 2, lower, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: learned casing update failed")
            return
        }
        learned?[lower] = word
        print("UsageStore: learned casing '\(stored)' -> '\(word)'")
    }

    /// Personal usage count for a word (0 if never seen). Backed by an in-memory
    /// cache; safe to call per swipe candidate (a dictionary hit, no SQL).
    func personalCount(for wordLower: String) -> Int {
        loadPersonalCounts()[wordLower] ?? 0
    }

    /// Promotes a word to the learned set (idempotent). `reason` is echoed for
    /// diagnostics ("usage" for threshold promotions, "rejection" for the
    /// autocorrect-rejection fast-track).
    func markLearned(_ word: String, reason: String = "usage") {
        guard Self.isLearnableWord(word), let db = connection() else { return }
        let lower = word.lowercased()

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO learned_words (word_lower, word, learned_at) VALUES (?, ?, ?)
            ON CONFLICT(word_lower) DO NOTHING
            """, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare learned insert")
            return
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, word, -1, transient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: learned insert failed")
            return
        }

        // Only log/cache the first time (ON CONFLICT DO NOTHING left prior rows
        // intact), so repeat calls stay quiet and idempotent.
        if loadLearned()[lower] == nil {
            learned?[lower] = word
            print("UsageStore: learned '\(word)' (count \(personalCount(for: lower)), \(reason))")
        }
    }

    /// Whether the personal dictionary knows this word — learned from typing
    /// or supplied by iOS for this session.
    func isLearned(_ wordLower: String) -> Bool {
        loadLearned()[wordLower] != nil || externalWords[wordLower] != nil
    }

    /// Stored casing for a personal-dictionary word, or nil if unknown.
    /// Learned casing wins over the iOS-provided one: it tracks the user's own
    /// mid-sentence behavior (see refreshLearnedCasing).
    func learnedWord(for wordLower: String) -> String? {
        loadLearned()[wordLower] ?? externalWords[wordLower]
    }

    /// The whole personal dictionary in stored casing, for candidate
    /// generation — learned words plus this session's iOS-provided words.
    func learnedWords() -> [String] {
        var merged = loadLearned()
        for (lower, word) in externalWords where merged[lower] == nil {
            merged[lower] = word
        }
        return Array(merged.values)
    }

    /// Replaces this session's iOS-provided words (UILexicon: contact names,
    /// single-word text replacements). Session-scoped and never persisted —
    /// iOS owns the source and it changes as contacts do. Entries failing word
    /// hygiene (multi-word phrases, emails) are dropped; the cap bounds the
    /// per-keystroke correction scan against enormous address books.
    func setExternalWords(_ words: [String]) {
        var accepted: [String: String] = [:]
        for word in words where Self.isLearnableWord(word) {
            let lower = word.lowercased()
            if accepted[lower] == nil {
                accepted[lower] = word
                if accepted.count >= Self.externalWordCap { break }
            }
        }
        externalWords = accepted
        if !accepted.isEmpty {
            print("UsageStore: \(accepted.count) supplementary words from UILexicon")
        }
    }

    // MARK: - Cache loading

    @discardableResult
    private func loadPersonalCounts() -> [String: Int] {
        if let personalCounts { return personalCounts }
        var result: [String: Int] = [:]
        if let db = connection() {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT word_lower, count FROM word_usage", -1, &stmt, nil) == SQLITE_OK,
               let statement = stmt {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let wordPtr = sqlite3_column_text(statement, 0) {
                        result[String(cString: wordPtr)] = Int(sqlite3_column_int64(statement, 1))
                    }
                }
                sqlite3_finalize(statement)
            }
        }
        personalCounts = result
        return result
    }

    @discardableResult
    private func loadLearned() -> [String: String] {
        if let learned { return learned }
        var result: [String: String] = [:]
        if let db = connection() {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT word_lower, word FROM learned_words", -1, &stmt, nil) == SQLITE_OK,
               let statement = stmt {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let lowerPtr = sqlite3_column_text(statement, 0),
                       let wordPtr = sqlite3_column_text(statement, 1) {
                        result[String(cString: lowerPtr)] = String(cString: wordPtr)
                    }
                }
                sqlite3_finalize(statement)
            }
        }
        learned = result
        return result
    }

    /// Word hygiene: 2–24 characters, letters and interior apostrophes only
    /// (mirrors `SuggestionService.isWordCharacter`). Anything else is silently
    /// ignored so we never learn punctuation, numbers, or fragments.
    private static func isLearnableWord(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count >= 2, chars.count <= 24 else { return false }
        for (i, ch) in chars.enumerated() {
            if ch.isLetter { continue }
            if ch == "'" {
                let hasLetterBefore = i > 0 && chars[i - 1].isLetter
                let hasLetterAfter = i < chars.count - 1 && chars[i + 1].isLetter
                if hasLetterBefore && hasLetterAfter { continue }
            }
            return false
        }
        return true
    }

    // MARK: - Lazy open

    /// Returns the open database, opening and provisioning it on first use.
    private func connection() -> OpaquePointer? {
        if let db = db { return db }
        if openFailed { return nil }
        guard let opened = openAndProvision() else {
            openFailed = true
            return nil
        }
        db = opened
        return opened
    }

    private func openAndProvision() -> OpaquePointer? {
        let directory = dbURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK, let opened = handle else {
            print("UsageStore: could not open \(dbURL.path)")
            if handle != nil { sqlite3_close(handle) }
            return nil
        }

        exec(opened, "PRAGMA journal_mode=WAL;")
        exec(opened, Self.schemaSQL)
        return opened
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS swipe_corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            layout TEXT NOT NULL,
            keyboard_width REAL NOT NULL,
            keyboard_height REAL NOT NULL,
            key_pitch REAL NOT NULL,
            committed TEXT NOT NULL,
            corrected TEXT NOT NULL,
            ranked TEXT NOT NULL,
            path TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tap_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL,
            typed TEXT NOT NULL,
            resolved TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS counters (
            name TEXT PRIMARY KEY,
            value INTEGER NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS word_usage (
            word_lower TEXT PRIMARY KEY,
            word TEXT NOT NULL,
            count INTEGER NOT NULL,
            last_used REAL NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS learned_words (
            word_lower TEXT PRIMARY KEY,
            word TEXT NOT NULL,
            learned_at REAL NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        -- v1 → v2 migration is nothing but the additive IF NOT EXISTS tables
        -- above; stamp the version unconditionally (INSERT OR IGNORE would leave
        -- an existing v1 row untouched).
        INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '2');
        """

    // MARK: - Helpers

    /// Retain only the newest `cap` rows; delete everything older. A no-op when
    /// the table holds `cap` rows or fewer (the OFFSET subquery yields no id).
    private func trim(_ db: OpaquePointer, table: String, cap: Int) {
        exec(db, """
            DELETE FROM \(table) WHERE id <= (
                SELECT id FROM \(table) ORDER BY id DESC LIMIT 1 OFFSET \(cap)
            )
            """)
    }

    private func jsonArray(_ items: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            print("UsageStore: exec failed: \(message)")
            sqlite3_free(errorMessage)
            return false
        }
        return true
    }
}
