//
//  DictionaryMerge.swift
//  Canary
//
//  Created by Claude on 7/5/26.
//

import Foundation

/// Deterministic merge rules for syncing the personal dictionary across
/// devices. Pure and total — same inputs, same output, no I/O; the sync
/// engine maps CKRecords and local rows into these states, merges, and writes
/// back whatever wins. Every rule is documented at its branch:
///
/// - count: max(local, remote). A monotonic counter never double-counts a
///   synced value and never loses the larger history; the alternative (sum
///   minus a common base) needs a per-device ledger — complexity rejected.
///   Counts are a prior, not an invoice.
/// - casing / phrase: newer updatedAt wins; ties break lexicographically
///   smaller (pure determinism without device identity).
/// - learned / tombstoned tri-state: newer updatedAt wins; ties prefer the
///   tombstone (destructive but recoverable: re-learning is one rejection
///   tap, un-deleting a nag is more annoying), then prefer learned over
///   neither (any signal beats none).
/// - Absence is not deletion: a record existing on only one side wins
///   outright and propagates. Only an explicit tombstone deletes.
/// - Tombstones are retained 90 days after updatedAt, then hard-deleted by
///   the sync pass (isExpiredTombstone).
enum DictionaryMerge {
    struct WordState: Equatable {
        var word: String        // stored casing
        var count: Int
        var learned: Bool
        var tombstoned: Bool
        var updatedAt: Date
    }

    struct ShortcutState: Equatable {
        var trigger: String     // stored casing
        var phrase: String
        var tombstoned: Bool
        var updatedAt: Date
    }

    /// Days a tombstone is retained before hard deletion.
    static let tombstoneRetentionDays: Double = 90

    static func merge(local: WordState?, remote: WordState?) -> WordState? {
        switch (local, remote) {
        case (nil, nil):
            return nil
        case (let only?, nil), (nil, let only?):
            // Absence is not deletion: the existing side wins and propagates.
            return only
        case (let l?, let r?):
            var result = l
            // count: max — monotonic, no double-count, no lost history.
            result.count = max(l.count, r.count)
            // casing: newer wins; tie → lexicographically smaller.
            if l.updatedAt != r.updatedAt {
                result.word = (l.updatedAt > r.updatedAt ? l : r).word
            } else {
                result.word = min(l.word, r.word)
            }
            // learned/tombstoned tri-state: newer wins; tie → tombstone, then
            // learned over neither.
            let stateSource: WordState
            if l.updatedAt != r.updatedAt {
                stateSource = l.updatedAt > r.updatedAt ? l : r
            } else if l.tombstoned != r.tombstoned {
                stateSource = l.tombstoned ? l : r
            } else if l.learned != r.learned {
                stateSource = l.learned ? l : r
            } else {
                stateSource = l
            }
            result.learned = stateSource.learned && !stateSource.tombstoned
            result.tombstoned = stateSource.tombstoned
            result.updatedAt = max(l.updatedAt, r.updatedAt)
            return result
        }
    }

    static func merge(local: ShortcutState?, remote: ShortcutState?) -> ShortcutState? {
        switch (local, remote) {
        case (nil, nil):
            return nil
        case (let only?, nil), (nil, let only?):
            return only
        case (let l?, let r?):
            var result = l
            // phrase (and trigger casing): newer wins; tie → smaller phrase.
            if l.updatedAt != r.updatedAt {
                let newer = l.updatedAt > r.updatedAt ? l : r
                result.trigger = newer.trigger
                result.phrase = newer.phrase
            } else if l.phrase != r.phrase {
                let winner = l.phrase < r.phrase ? l : r
                result.trigger = winner.trigger
                result.phrase = winner.phrase
            }
            // tombstone tri-state, same rule as words.
            if l.updatedAt != r.updatedAt {
                result.tombstoned = (l.updatedAt > r.updatedAt ? l : r).tombstoned
            } else {
                result.tombstoned = l.tombstoned || r.tombstoned
            }
            result.updatedAt = max(l.updatedAt, r.updatedAt)
            return result
        }
    }

    /// Whether a tombstoned record is past retention and may be hard-deleted
    /// (locally and from CloudKit) by the sync pass.
    static func isExpiredTombstone(tombstoned: Bool, updatedAt: Date, now: Date) -> Bool {
        tombstoned && now.timeIntervalSince(updatedAt) > tombstoneRetentionDays * 86_400
    }
}
