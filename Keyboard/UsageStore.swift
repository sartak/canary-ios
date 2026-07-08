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
    case shortcutExpanded = "shortcut_expanded"
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
    /// Un-learn tombstones (dictionary UI removals), lazily loaded like the
    /// learned cache. A tombstoned word cannot re-promote by usage count.
    private var unlearned: Set<String>?
    /// Custom trigger→phrase shortcuts keyed by lowercased trigger, lazily
    /// loaded from the shortcuts table and kept in sync by add/remove.
    private var shortcutCache: [String: String]?
    /// iOS text-replacement pairs for this session (UILexicon entries whose
    /// sides differ), lowercased trigger → phrase. In-memory only.
    private var externalShortcuts: [String: String] = [:]

    /// Upper bound on session shortcut pairs accepted from UILexicon.
    private static let externalShortcutCap = 500

    /// Upper bound on session words accepted from UILexicon.
    private static let externalWordCap = 2000

    /// App Group shared with the containing app so its dictionary UI can see
    /// this database. Keyboard extensions can only ACCESS the group container
    /// when the user grants Full Access; `containerURL` returns a path either
    /// way, so usability is determined by whether the open succeeds (see
    /// openAndProvision's fallback).
    static let appGroupID = "group.net.rpglanguage.Canary"

    /// The extension-private location usage.db lived at before the App Group;
    /// the migration source, and the fallback when Full Access is off.
    private let legacyDBURL: URL?

    /// Resolves the on-disk paths; does NOT open the database yet.
    init?() {
        let legacy = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ))?.appendingPathComponent("usage.db")

        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) {
            self.dbURL = group.appendingPathComponent("usage.db")
            self.legacyDBURL = legacy
        } else if let legacy {
            self.dbURL = legacy
            self.legacyDBURL = nil
        } else {
            print("UsageStore: could not resolve a database location")
            return nil
        }
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
                  count = count + 1, word = excluded.word, last_used = excluded.last_used, dirty = 1
              """
            : """
              INSERT INTO word_usage (word_lower, word, count, last_used) VALUES (?, ?, 1, ?)
              ON CONFLICT(word_lower) DO UPDATE SET
                  count = count + 1, last_used = excluded.last_used, dirty = 1
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
        guard sqlite3_prepare_v2(db, "UPDATE learned_words SET word = ?, dirty = 1 WHERE word_lower = ?",
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

        // An un-learn tombstone (dictionary UI removal) blocks re-promotion by
        // usage count — except for the rejection fast-track: explicitly
        // defending the word from an autocorrect overrides the earlier removal.
        if loadUnlearned().contains(lower) {
            guard reason == "rejection" else { return }
            removeTombstone(lower, db: db)
        }

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

    /// Memory-pressure hook. The lazy caches reload from usage.db on next
    /// read; iOS-provided session words are NOT dropped (they cannot be
    /// re-fetched until the next keyboard launch).
    func releaseMemory() {
        personalCounts = nil
        learned = nil
        unlearned = nil
        shortcutCache = nil
        if let db {
            sqlite3_db_release_memory(db)
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

    @discardableResult
    private func loadUnlearned() -> Set<String> {
        if let unlearned { return unlearned }
        var result: Set<String> = []
        if let db = connection() {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT word_lower FROM unlearned_words", -1, &stmt, nil) == SQLITE_OK,
               let statement = stmt {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let lowerPtr = sqlite3_column_text(statement, 0) {
                        result.insert(String(cString: lowerPtr))
                    }
                }
                sqlite3_finalize(statement)
            }
        }
        unlearned = result
        return result
    }

    private func removeTombstone(_ lower: String, db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM unlearned_words WHERE word_lower = ?", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, lower, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = sqlite3_step(statement)
        unlearned?.remove(lower)
    }

    // MARK: - Shortcuts (Milestone 10)

    /// Custom trigger→phrase map keyed by lowercased trigger.
    func shortcuts() -> [String: String] {
        if let shortcutCache { return shortcutCache }
        var result: [String: String] = [:]
        if let db = connection() {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT trigger_lower, phrase FROM shortcuts WHERE deleted = 0", -1, &stmt, nil) == SQLITE_OK,
               let statement = stmt {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let triggerPtr = sqlite3_column_text(statement, 0),
                       let phrasePtr = sqlite3_column_text(statement, 1) {
                        result[String(cString: triggerPtr)] = String(cString: phrasePtr)
                    }
                }
                sqlite3_finalize(statement)
            }
        }
        shortcutCache = result
        return result
    }

    /// Upserts a custom shortcut; hygiene-guarded (see the validators below).
    func addShortcut(trigger: String, phrase: String) {
        guard Self.isValidShortcutTrigger(trigger),
              let cleanPhrase = Self.normalizedShortcutPhrase(phrase),
              trigger.lowercased() != cleanPhrase.lowercased(),
              let db = connection() else { return }
        let lower = trigger.lowercased()

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO shortcuts (trigger_lower, trigger, phrase, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(trigger_lower) DO UPDATE SET
                trigger = excluded.trigger, phrase = excluded.phrase,
                created_at = excluded.created_at, dirty = 1, deleted = 0
            """, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("UsageStore: could not prepare shortcut upsert")
            return
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, trigger, -1, transient)
        sqlite3_bind_text(statement, 3, cleanPhrase, -1, transient)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("UsageStore: shortcut upsert failed")
            return
        }
        shortcutCache?[lower] = cleanPhrase
        print("UsageStore: shortcut '\(trigger)' -> '\(cleanPhrase)'")
    }

    func removeShortcut(triggerLower: String) {
        guard let db = connection() else { return }
        var stmt: OpaquePointer?
        // Soft delete: the tombstone row is what propagates the deletion to
        // other devices (absence is not deletion in the merge rules).
        guard sqlite3_prepare_v2(db, "UPDATE shortcuts SET deleted = 1, dirty = 1, created_at = ? WHERE trigger_lower = ?", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, triggerLower, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = sqlite3_step(statement)
        shortcutCache?.removeValue(forKey: triggerLower)
    }

    /// Replaces this session's iOS text-replacement pairs (UILexicon entries
    /// whose sides differ — including the multi-word phrases the word path
    /// drops). Session-scoped, never persisted; hygiene-filtered and capped.
    func setExternalShortcuts(_ pairs: [(trigger: String, phrase: String)]) {
        var accepted: [String: String] = [:]
        for pair in pairs {
            guard Self.isValidShortcutTrigger(pair.trigger),
                  let phrase = Self.normalizedShortcutPhrase(pair.phrase),
                  pair.trigger.lowercased() != phrase.lowercased() else { continue }
            let lower = pair.trigger.lowercased()
            if accepted[lower] == nil {
                accepted[lower] = phrase
                if accepted.count >= Self.externalShortcutCap { break }
            }
        }
        externalShortcuts = accepted
        if !accepted.isEmpty {
            print("UsageStore: \(accepted.count) text-replacement pairs from UILexicon")
        }
    }

    /// Expansion phrase for a committed token, or nil. Custom shortcuts win
    /// over iOS-provided pairs on trigger collision (the user defined them
    /// explicitly in our app; the iOS pair still exists system-wide).
    func shortcutPhrase(for triggerLower: String) -> String? {
        shortcuts()[triggerLower] ?? externalShortcuts[triggerLower]
    }

    /// Trigger hygiene: 2–24 characters, letters/digits/interior apostrophes,
    /// no whitespace, at least one letter.
    static func isValidShortcutTrigger(_ trigger: String) -> Bool {
        guard trigger.count >= 2, trigger.count <= 24 else { return false }
        for (offset, character) in trigger.enumerated() {
            if character.isLetter || character.isNumber { continue }
            if character == "'", offset > 0, offset < trigger.count - 1 { continue }
            return false
        }
        return trigger.contains { $0.isLetter }
    }

    /// Phrase hygiene: trimmed, 1–200 characters, single line.
    static func normalizedShortcutPhrase(_ phrase: String) -> String? {
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 200,
              !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }

    /// The app process may have edited the database (un-learn, add, casing,
    /// shortcuts) while this keyboard process was alive; drop the caches so
    /// the next read sees its changes. Called when the keyboard (re)appears.
    func invalidateCaches() {
        personalCounts = nil
        learned = nil
        unlearned = nil
        shortcutCache = nil
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
        migrateLegacyDatabaseIfNeeded()
        if let opened = open(at: dbURL) {
            return opened
        }
        // Group container unusable (Full Access off): the keyboard keeps
        // working from the extension-private location; only the app's
        // dictionary UI loses sight of the data.
        if let legacyDBURL, legacyDBURL != dbURL {
            print("UsageStore: group container unusable; falling back to the private container")
            return open(at: legacyDBURL)
        }
        return nil
    }

    private func open(at url: URL) -> OpaquePointer? {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let opened = handle else {
            print("UsageStore: could not open \(url.path)")
            if handle != nil { sqlite3_close(handle) }
            return nil
        }

        exec(opened, "PRAGMA journal_mode=WAL;")
        // The app process shares this database now; briefly wait out its
        // writes instead of failing statements.
        exec(opened, "PRAGMA busy_timeout=250;")
        migrateForSync(opened)
        exec(opened, Self.schemaSQL)
        return opened
    }

    /// Pre-v5 databases lack the sync bookkeeping columns; fresh databases get
    /// them from the CREATE statements, so the ALTERs run exactly once, gated
    /// on the recorded version (everything starts dirty: never-synced rows
    /// must push).
    private func migrateForSync(_ db: OpaquePointer) {
        var version = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'schema_version'", -1, &stmt, nil) == SQLITE_OK,
           let statement = stmt {
            if sqlite3_step(statement) == SQLITE_ROW, let valuePtr = sqlite3_column_text(statement, 0) {
                version = Int(String(cString: valuePtr)) ?? 0
            }
            sqlite3_finalize(statement)
        }
        guard version >= 1, version < 5 else { return }
        for table in ["word_usage", "learned_words", "unlearned_words", "shortcuts"] {
            exec(db, "ALTER TABLE \(table) ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;")
        }
        // Shortcut deletions must propagate as tombstones (absence is not
        // deletion in the merge rules), so removal is a soft delete.
        exec(db, "ALTER TABLE shortcuts ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;")
        print("UsageStore: migrated schema v\(version) for sync bookkeeping")
    }

    /// One-time move of usage.db (plus WAL sidecars, which carry unflushed
    /// commits) from the extension-private container into the App Group.
    /// Without Full Access the moves fail silently and the fallback keeps
    /// using the legacy file; the migration then runs when access is granted.
    private func migrateLegacyDatabaseIfNeeded() {
        guard let legacyDBURL, legacyDBURL != dbURL,
              FileManager.default.fileExists(atPath: legacyDBURL.path),
              !FileManager.default.fileExists(atPath: dbURL.path) else { return }

        let directory = dbURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var movedMain = false
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacyDBURL.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: dbURL.path + suffix)
            do {
                try FileManager.default.moveItem(at: from, to: to)
                if suffix.isEmpty { movedMain = true }
            } catch {
                if suffix.isEmpty { return }  // main file didn't move; sidecars stay with it
            }
        }
        if movedMain {
            print("UsageStore: migrated usage.db into the app group container")
        }
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
            last_used REAL NOT NULL,
            dirty INTEGER NOT NULL DEFAULT 1
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS learned_words (
            word_lower TEXT PRIMARY KEY,
            word TEXT NOT NULL,
            learned_at REAL NOT NULL,
            dirty INTEGER NOT NULL DEFAULT 1
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS unlearned_words (
            word_lower TEXT PRIMARY KEY,
            unlearned_at REAL NOT NULL,
            dirty INTEGER NOT NULL DEFAULT 1
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS shortcuts (
            trigger_lower TEXT PRIMARY KEY,
            trigger TEXT NOT NULL,
            phrase TEXT NOT NULL,
            created_at REAL NOT NULL,
            dirty INTEGER NOT NULL DEFAULT 1,
            deleted INTEGER NOT NULL DEFAULT 0
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS sync_state (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        -- Migrations so far are purely additive IF NOT EXISTS tables; stamp the
        -- version unconditionally (INSERT OR IGNORE would leave an old row).
        INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '5');
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
