//
//  SwipeLexicon.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import Foundation
import SQLite3

struct SwipeLexiconEntry {
    let word: String
    let frequencyRank: Int
    /// Occurrence count from the Google Web Trillion Word Corpus
    /// (Norvig count_1w.txt); the swipe prior is frequency / totalFrequency.
    let frequency: Int
}

/// Frequency-ranked candidate retrieval for swipe decoding, pruned by the
/// letters near the path's endpoints (swiping.md §4.4). Backed by the
/// idx_words_swipe covering index — no table scan.
final class SwipeLexicon {
    private let db: OpaquePointer

    init(db: OpaquePointer) {
        self.db = db
    }

    /// Total occurrence count across visible words, for normalizing the prior.
    lazy var totalFrequency: Int = {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT SUM(frequency) FROM words WHERE hidden = 0", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else {
            return 1
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 1 }
        return max(Int(sqlite3_column_int64(statement, 0)), 1)
    }()

    /// Candidates for a completed swipe: first and last letters constrained.
    func candidates(startingWith startLetters: Set<Character>,
                    endingWith endLetters: Set<Character>,
                    limit: Int) -> [SwipeLexiconEntry] {
        query(startLetters: startLetters, endLetters: endLetters, limit: limit)
    }

    /// Candidates for an in-progress swipe: only the first letter is known.
    func candidates(startingWith startLetters: Set<Character>,
                    limit: Int) -> [SwipeLexiconEntry] {
        query(startLetters: startLetters, endLetters: nil, limit: limit)
    }

    private func query(startLetters: Set<Character>,
                       endLetters: Set<Character>?,
                       limit: Int) -> [SwipeLexiconEntry] {
        guard !startLetters.isEmpty, limit > 0 else { return [] }
        if let endLetters, endLetters.isEmpty { return [] }

        var sql = """
            SELECT word, frequency_rank, frequency FROM words
            WHERE first_char IN (\(placeholders(startLetters.count)))
            """
        if let endLetters {
            sql += " AND last_char IN (\(placeholders(endLetters.count)))"
        }
        sql += " AND hidden = 0 AND distinct_key_count >= 2 ORDER BY frequency_rank LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var index: Int32 = 1
        for letter in startLetters {
            sqlite3_bind_text(statement, index, String(letter).lowercased(), -1, transient)
            index += 1
        }
        for letter in endLetters ?? [] {
            sqlite3_bind_text(statement, index, String(letter).lowercased(), -1, transient)
            index += 1
        }
        sqlite3_bind_int(statement, index, Int32(limit))

        var entries: [SwipeLexiconEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let wordPtr = sqlite3_column_text(statement, 0) {
                entries.append(SwipeLexiconEntry(
                    word: String(cString: wordPtr),
                    frequencyRank: Int(sqlite3_column_int64(statement, 1)),
                    frequency: Int(sqlite3_column_int64(statement, 2))
                ))
            }
        }
        return entries
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
