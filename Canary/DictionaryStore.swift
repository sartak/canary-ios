//
//  DictionaryStore.swift
//  Canary
//
//  Created by Claude on 7/5/26.
//

import Foundation
import SQLite3

/// App-side access to the keyboard's shared usage.db (App Group container).
///
/// The keyboard is the sole schema owner and migrator: this store only reads
/// and writes tables that already exist, opening the database without the
/// CREATE flag. When the file is absent — Full Access was never granted, or
/// the keyboard hasn't run since the App Group landed — `open()` fails and the
/// UI shows an explainer instead. Raw SQLite in the keyboard's house style;
/// the two targets deliberately share no code.
final class DictionaryStore {
    struct Entry: Identifiable {
        let word: String
        let wordLower: String
        let count: Int
        let learnedAt: Date
        var id: String { wordLower }
    }

    /// Mirrors UsageStore.appGroupID (no shared code across the targets).
    static let appGroupID = "group.net.rpglanguage.Canary"

    private let db: OpaquePointer

    /// nil when the shared database cannot be opened (no Full Access, or the
    /// keyboard has never run against the group container).
    init?() {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return nil }
        let url = group.appendingPathComponent("usage.db")

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let opened = handle else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        db = opened
        // The keyboard process shares this database; briefly wait out its
        // writes instead of failing statements.
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "PRAGMA busy_timeout=250;", nil, nil, &err)
        sqlite3_free(err)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Learned words with their usage counts, most-used first.
    func entries() -> [Entry] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT lw.word, lw.word_lower, COALESCE(wu.count, 0), lw.learned_at
            FROM learned_words lw
            LEFT JOIN word_usage wu ON wu.word_lower = lw.word_lower
            ORDER BY COALESCE(wu.count, 0) DESC, lw.word_lower ASC
            """, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let wordPtr = sqlite3_column_text(statement, 0),
                  let lowerPtr = sqlite3_column_text(statement, 1) else { continue }
            result.append(Entry(
                word: String(cString: wordPtr),
                wordLower: String(cString: lowerPtr),
                count: Int(sqlite3_column_int64(statement, 2)),
                learnedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return result
    }

    /// Removes a learned word AND tombstones it, so its usage count (already
    /// past the promotion threshold) cannot immediately re-learn it. The
    /// keyboard's rejection fast-track can still override the tombstone.
    func unlearn(_ wordLower: String) {
        exec("BEGIN")
        run("INSERT OR REPLACE INTO unlearned_words (word_lower, unlearned_at) VALUES (?, ?)",
            texts: [wordLower], doubles: [Date().timeIntervalSince1970])
        run("DELETE FROM learned_words WHERE word_lower = ?", texts: [wordLower])
        exec("COMMIT")
    }

    /// Adds a word to the learned set (clearing any tombstone). Returns false
    /// on a hygiene failure. Hygiene mirrors UsageStore.isLearnableWord: 2–24
    /// characters, letters and interior apostrophes only.
    @discardableResult
    func add(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard Self.isLearnableWord(trimmed) else { return false }
        let lower = trimmed.lowercased()
        exec("BEGIN")
        run("DELETE FROM unlearned_words WHERE word_lower = ?", texts: [lower])
        run("INSERT OR REPLACE INTO learned_words (word_lower, word, learned_at) VALUES (?, ?, ?)",
            texts: [lower, trimmed], doubles: [Date().timeIntervalSince1970])
        exec("COMMIT")
        return true
    }

    struct Tombstone: Identifiable {
        let wordLower: String
        let unlearnedAt: Date
        var id: String { wordLower }
    }

    /// Un-learned (tombstoned) words, newest removals first. Only the
    /// lowercased form exists — the learned row is gone by definition.
    func tombstones() -> [Tombstone] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT word_lower, unlearned_at FROM unlearned_words ORDER BY unlearned_at DESC", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [Tombstone] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let lowerPtr = sqlite3_column_text(statement, 0) else { continue }
            result.append(Tombstone(
                wordLower: String(cString: lowerPtr),
                unlearnedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            ))
        }
        return result
    }

    /// Erases every local trace of a word: tombstone, learned row, usage
    /// counts. The word can then be learned again from scratch. Pair with
    /// DictionarySync.hardDeleteWords — without the CloudKit record deletion,
    /// the next sync would just re-download the tombstone.
    func hardDeleteWord(_ wordLower: String) {
        exec("BEGIN")
        for table in ["unlearned_words", "learned_words", "word_usage"] {
            run("DELETE FROM \(table) WHERE word_lower = ?", texts: [wordLower])
        }
        exec("COMMIT")
    }

    // MARK: - Shortcuts

    struct Shortcut: Identifiable {
        let trigger: String
        let triggerLower: String
        let phrase: String
        var id: String { triggerLower }
    }

    /// Custom shortcuts, alphabetical by trigger. iOS-provided text
    /// replacements (Settings) are not listed here — they are managed in
    /// Settings and only mirrored per keyboard session.
    func shortcuts() -> [Shortcut] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT trigger, trigger_lower, phrase FROM shortcuts WHERE deleted = 0 ORDER BY trigger_lower ASC", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [Shortcut] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let triggerPtr = sqlite3_column_text(statement, 0),
                  let lowerPtr = sqlite3_column_text(statement, 1),
                  let phrasePtr = sqlite3_column_text(statement, 2) else { continue }
            result.append(Shortcut(
                trigger: String(cString: triggerPtr),
                triggerLower: String(cString: lowerPtr),
                phrase: String(cString: phrasePtr)
            ))
        }
        return result
    }

    /// Upserts a custom shortcut. Returns false on a hygiene failure.
    /// Hygiene mirrors UsageStore's validators (duplicated by design — the
    /// targets share no code): trigger 2–24 chars of letters/digits/interior
    /// apostrophes with at least one letter and no whitespace; phrase trimmed,
    /// single-line, 1–200 chars, not equal to the trigger.
    @discardableResult
    func addShortcut(trigger: String, phrase: String) -> Bool {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespaces)
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespaces)
        guard Self.isValidShortcutTrigger(trimmedTrigger),
              !trimmedPhrase.isEmpty, trimmedPhrase.count <= 200,
              !trimmedPhrase.contains(where: \.isNewline),
              trimmedTrigger.lowercased() != trimmedPhrase.lowercased() else { return false }
        run("""
            INSERT INTO shortcuts (trigger_lower, trigger, phrase, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(trigger_lower) DO UPDATE SET
                trigger = excluded.trigger, phrase = excluded.phrase,
                created_at = excluded.created_at, dirty = 1, deleted = 0
            """,
            texts: [trimmedTrigger.lowercased(), trimmedTrigger, trimmedPhrase],
            doubles: [Date().timeIntervalSince1970])
        return true
    }

    func removeShortcut(_ triggerLower: String) {
        // Soft delete: the tombstone propagates the deletion to other devices.
        // Numbered placeholders: run() binds texts before doubles.
        run("UPDATE shortcuts SET deleted = 1, dirty = 1, created_at = ?2 WHERE trigger_lower = ?1",
            texts: [triggerLower], doubles: [Date().timeIntervalSince1970])
    }

    private static func isValidShortcutTrigger(_ trigger: String) -> Bool {
        guard trigger.count >= 2, trigger.count <= 24 else { return false }
        for (offset, character) in trigger.enumerated() {
            if character.isLetter || character.isNumber { continue }
            if character == "'", offset > 0, offset < trigger.count - 1 { continue }
            return false
        }
        return trigger.contains { $0.isLetter }
    }

    /// Mirror of the keyboard's word hygiene (UsageStore.isLearnableWord).
    /// Duplicated by design: the targets share no code, and a mismatch is
    /// merely cosmetic — the keyboard's reads don't re-validate.
    private static func isLearnableWord(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= 24 else { return false }
        for (offset, character) in word.enumerated() {
            if character.isLetter { continue }
            if character == "'", offset > 0, offset < word.count - 1 { continue }
            return false
        }
        return word.contains { $0.isLetter }
    }

    // MARK: - Sync support (DictionarySync)

    /// Serialized CKSyncEngine state, persisted beside the data it describes.
    func syncStateData() -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM sync_state WHERE key = 'engine_state'", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func setSyncStateData(_ data: Data) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('engine_state', ?)", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else { return }
        defer { sqlite3_finalize(statement) }
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_step(statement)
        }
    }

    /// word_lowers with un-pushed changes in any of the three word tables.
    func dirtyWordKeys() -> [String] {
        queryStrings("""
            SELECT word_lower FROM word_usage WHERE dirty = 1
            UNION SELECT word_lower FROM learned_words WHERE dirty = 1
            UNION SELECT word_lower FROM unlearned_words WHERE dirty = 1
            """)
    }

    func dirtyShortcutKeys() -> [String] {
        queryStrings("SELECT trigger_lower FROM shortcuts WHERE dirty = 1")
    }

    /// Composite view over the three word tables, in merge-rule shape.
    /// updatedAt is the newest of the row timestamps.
    func wordState(for wordLower: String) -> DictionaryMerge.WordState? {
        var word = wordLower
        var count = 0
        var lastUsed: Double = 0
        var found = false

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT word, count, last_used FROM word_usage WHERE word_lower = ?", -1, &stmt, nil) == SQLITE_OK,
           let statement = stmt {
            sqlite3_bind_text(statement, 1, wordLower, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(statement) == SQLITE_ROW {
                if let wordPtr = sqlite3_column_text(statement, 0) { word = String(cString: wordPtr) }
                count = Int(sqlite3_column_int64(statement, 1))
                lastUsed = sqlite3_column_double(statement, 2)
                found = true
            }
            sqlite3_finalize(statement)
        }

        var learnedAt: Double?
        if sqlite3_prepare_v2(db, "SELECT learned_at, word FROM learned_words WHERE word_lower = ?", -1, &stmt, nil) == SQLITE_OK,
           let statement = stmt {
            sqlite3_bind_text(statement, 1, wordLower, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(statement) == SQLITE_ROW {
                learnedAt = sqlite3_column_double(statement, 0)
                if let wordPtr = sqlite3_column_text(statement, 1) { word = String(cString: wordPtr) }
                found = true
            }
            sqlite3_finalize(statement)
        }

        var unlearnedAt: Double?
        if sqlite3_prepare_v2(db, "SELECT unlearned_at FROM unlearned_words WHERE word_lower = ?", -1, &stmt, nil) == SQLITE_OK,
           let statement = stmt {
            sqlite3_bind_text(statement, 1, wordLower, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(statement) == SQLITE_ROW {
                unlearnedAt = sqlite3_column_double(statement, 0)
                found = true
            }
            sqlite3_finalize(statement)
        }

        guard found else { return nil }
        return DictionaryMerge.WordState(
            word: word,
            count: count,
            learned: learnedAt != nil,
            tombstoned: unlearnedAt != nil,
            updatedAt: Date(timeIntervalSince1970: max(lastUsed, learnedAt ?? 0, unlearnedAt ?? 0))
        )
    }

    /// Writes a merged state across the three word tables. markDirty re-queues
    /// the row for push (the merge produced something the remote lacks).
    func applyWordState(_ state: DictionaryMerge.WordState, for wordLower: String, markDirty: Bool) {
        let dirty = markDirty ? 1 : 0
        let stamp = state.updatedAt.timeIntervalSince1970
        exec("BEGIN")
        if state.count > 0 {
            run("INSERT OR REPLACE INTO word_usage (word_lower, word, count, last_used, dirty) VALUES (?1, ?2, ?3, ?4, \(dirty))",
                texts: [wordLower, state.word], ints: [state.count], doubles: [stamp])
        } else {
            run("DELETE FROM word_usage WHERE word_lower = ?", texts: [wordLower])
        }
        if state.learned {
            run("INSERT OR REPLACE INTO learned_words (word_lower, word, learned_at, dirty) VALUES (?1, ?2, ?3, \(dirty))",
                texts: [wordLower, state.word], doubles: [stamp])
        } else {
            run("DELETE FROM learned_words WHERE word_lower = ?", texts: [wordLower])
        }
        if state.tombstoned {
            run("INSERT OR REPLACE INTO unlearned_words (word_lower, unlearned_at, dirty) VALUES (?1, ?2, \(dirty))",
                texts: [wordLower], doubles: [stamp])
        } else {
            run("DELETE FROM unlearned_words WHERE word_lower = ?", texts: [wordLower])
        }
        exec("COMMIT")
    }

    func clearWordDirty(_ wordLower: String) {
        for table in ["word_usage", "learned_words", "unlearned_words"] {
            run("UPDATE \(table) SET dirty = 0 WHERE word_lower = ?", texts: [wordLower])
        }
    }

    /// Shortcut row in merge-rule shape (created_at doubles as updatedAt).
    func shortcutState(for triggerLower: String) -> DictionaryMerge.ShortcutState? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT trigger, phrase, created_at, deleted FROM shortcuts WHERE trigger_lower = ?", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, triggerLower, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let triggerPtr = sqlite3_column_text(statement, 0),
              let phrasePtr = sqlite3_column_text(statement, 1) else { return nil }
        return DictionaryMerge.ShortcutState(
            trigger: String(cString: triggerPtr),
            phrase: String(cString: phrasePtr),
            tombstoned: sqlite3_column_int64(statement, 3) != 0,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        )
    }

    func applyShortcutState(_ state: DictionaryMerge.ShortcutState, for triggerLower: String, markDirty: Bool) {
        let dirty = markDirty ? 1 : 0
        let deleted = state.tombstoned ? 1 : 0
        run("INSERT OR REPLACE INTO shortcuts (trigger_lower, trigger, phrase, created_at, dirty, deleted) VALUES (?1, ?2, ?3, ?4, \(dirty), \(deleted))",
            texts: [triggerLower, state.trigger, state.phrase],
            doubles: [state.updatedAt.timeIntervalSince1970])
    }

    func clearShortcutDirty(_ triggerLower: String) {
        run("UPDATE shortcuts SET dirty = 0 WHERE trigger_lower = ?", texts: [triggerLower])
    }

    /// Hard-deletes tombstones past retention; returns their keys so the sync
    /// engine can delete the CloudKit records too.
    func purgeExpiredTombstones(now: Date) -> (words: [String], shortcuts: [String]) {
        let cutoff = now.timeIntervalSince1970 - DictionaryMerge.tombstoneRetentionDays * 86_400
        let words = queryStrings("SELECT word_lower FROM unlearned_words WHERE unlearned_at < \(cutoff)")
        for word in words {
            run("DELETE FROM unlearned_words WHERE word_lower = ?", texts: [word])
        }
        let shortcuts = queryStrings("SELECT trigger_lower FROM shortcuts WHERE deleted = 1 AND created_at < \(cutoff)")
        for trigger in shortcuts {
            run("DELETE FROM shortcuts WHERE trigger_lower = ?", texts: [trigger])
        }
        return (words, shortcuts)
    }

    /// Wipes every typing-data table on this device: learned words,
    /// tombstones, usage counts, shortcuts, correction logs, counters.
    /// Deliberately NOT tombstone-based — pair with DictionarySync's zone
    /// deletion, or a live sync would simply re-download everything
    /// (absence is not deletion in the merge rules). Engine sync state is
    /// kept; the engine reconciles against the deleted zone itself.
    func resetAllTypingData() {
        exec("BEGIN")
        for table in ["word_usage", "learned_words", "unlearned_words", "shortcuts",
                      "tap_events", "swipe_corrections", "counters"] {
            exec("DELETE FROM \(table)")
        }
        exec("COMMIT")
    }

    /// Re-queues every row for push (account change / zone re-creation).
    func markAllDirty() {
        for table in ["word_usage", "learned_words", "unlearned_words", "shortcuts"] {
            exec("UPDATE \(table) SET dirty = 1")
        }
    }

    private func queryStrings(_ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(statement, 0) {
                result.append(String(cString: ptr))
            }
        }
        return result
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { print("DictionaryStore: exec failed: \(String(cString: err))") }
            sqlite3_free(err)
        }
    }

    /// Prepares, binds texts, then ints, then doubles (in that index order),
    /// and steps. Numbered placeholders (?1) may reorder within the SQL.
    private func run(_ sql: String, texts: [String] = [], ints: [Int] = [], doubles: [Double] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            print("DictionaryStore: could not prepare: \(sql)")
            return
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var index: Int32 = 1
        for text in texts {
            sqlite3_bind_text(statement, index, text, -1, transient)
            index += 1
        }
        for value in ints {
            sqlite3_bind_int64(statement, index, Int64(value))
            index += 1
        }
        for value in doubles {
            sqlite3_bind_double(statement, index, value)
            index += 1
        }
        if sqlite3_step(statement) != SQLITE_DONE {
            print("DictionaryStore: statement failed: \(sql)")
        }
    }
}
