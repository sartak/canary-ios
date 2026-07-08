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

    // MARK: - SQLite helpers

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { print("DictionaryStore: exec failed: \(String(cString: err))") }
            sqlite3_free(err)
        }
    }

    /// Prepares, binds texts then doubles (in that index order), and steps.
    private func run(_ sql: String, texts: [String] = [], doubles: [Double] = []) {
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
        for value in doubles {
            sqlite3_bind_double(statement, index, value)
            index += 1
        }
        if sqlite3_step(statement) != SQLITE_DONE {
            print("DictionaryStore: statement failed: \(sql)")
        }
    }
}
