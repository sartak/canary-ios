//
//  DictionaryMergeTests.swift
//  CanaryTests
//
//  Created by Claude on 7/5/26.
//

import Foundation
import Testing
@testable import Canary

private func word(_ word: String, count: Int = 0, learned: Bool = false,
                  tombstoned: Bool = false, at seconds: TimeInterval) -> DictionaryMerge.WordState {
    DictionaryMerge.WordState(word: word, count: count, learned: learned,
                              tombstoned: tombstoned,
                              updatedAt: Date(timeIntervalSince1970: seconds))
}

struct DictionaryMergeWordTests {
    @Test func absenceIsNotDeletion() {
        let only = word("claude", count: 3, learned: true, at: 100)
        #expect(DictionaryMerge.merge(local: only, remote: nil) == only)
        #expect(DictionaryMerge.merge(local: nil, remote: only) == only)
        #expect(DictionaryMerge.merge(local: nil, remote: nil) == nil)
    }

    @Test func countTakesTheMaximum() {
        let a = word("claude", count: 3, learned: true, at: 100)
        let b = word("claude", count: 2, learned: true, at: 200)
        let merged = DictionaryMerge.merge(local: a, remote: b)
        #expect(merged?.count == 3)
        // ...even though b is newer for everything else.
        #expect(merged?.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func casingFollowsTheNewerSide() {
        let older = word("claude", at: 100)
        let newer = word("Claude", at: 200)
        #expect(DictionaryMerge.merge(local: older, remote: newer)?.word == "Claude")
        #expect(DictionaryMerge.merge(local: newer, remote: older)?.word == "Claude")
    }

    @Test func casingTieBreaksLexicographically() {
        let a = word("Claude", at: 100)
        let b = word("claude", at: 100)
        // "Claude" < "claude" in unicode-scalar order — deterministic both ways.
        #expect(DictionaryMerge.merge(local: a, remote: b)?.word == "Claude")
        #expect(DictionaryMerge.merge(local: b, remote: a)?.word == "Claude")
    }

    @Test func newerUnlearnBeatsOlderLearn() {
        let learn = word("claude", learned: true, at: 100)
        let unlearn = word("claude", tombstoned: true, at: 200)
        let merged = DictionaryMerge.merge(local: learn, remote: unlearn)
        #expect(merged?.tombstoned == true)
        #expect(merged?.learned == false)
    }

    @Test func newerLearnBeatsOlderTombstone() {
        let unlearn = word("claude", tombstoned: true, at: 100)
        let relearn = word("claude", learned: true, at: 200)
        let merged = DictionaryMerge.merge(local: unlearn, remote: relearn)
        #expect(merged?.learned == true)
        #expect(merged?.tombstoned == false)
    }

    @Test func exactTiePrefersTheTombstone() {
        let learn = word("claude", learned: true, at: 100)
        let unlearn = word("claude", tombstoned: true, at: 100)
        #expect(DictionaryMerge.merge(local: learn, remote: unlearn)?.tombstoned == true)
        #expect(DictionaryMerge.merge(local: unlearn, remote: learn)?.tombstoned == true)
    }

    @Test func exactTiePrefersLearnedOverNeither() {
        let learn = word("claude", learned: true, at: 100)
        let neither = word("claude", at: 100)
        #expect(DictionaryMerge.merge(local: neither, remote: learn)?.learned == true)
        #expect(DictionaryMerge.merge(local: learn, remote: neither)?.learned == true)
    }

    @Test func offlineCountsDoNotSum() {
        // Typed 3x on A and 2x on B while offline: both converge on 3, not 5.
        let a = word("way", count: 3, at: 100)
        let b = word("way", count: 2, at: 150)
        #expect(DictionaryMerge.merge(local: a, remote: b)?.count == 3)
    }

    @Test func tombstoneExpiry() {
        let stamp = Date(timeIntervalSince1970: 0)
        let justInside = stamp.addingTimeInterval(90 * 86_400 - 1)
        let justPast = stamp.addingTimeInterval(90 * 86_400 + 1)
        #expect(!DictionaryMerge.isExpiredTombstone(tombstoned: true, updatedAt: stamp, now: justInside))
        #expect(DictionaryMerge.isExpiredTombstone(tombstoned: true, updatedAt: stamp, now: justPast))
        #expect(!DictionaryMerge.isExpiredTombstone(tombstoned: false, updatedAt: stamp, now: justPast))
    }
}

struct DictionaryMergeShortcutTests {
    private func shortcut(_ trigger: String, phrase: String, tombstoned: Bool = false,
                          at seconds: TimeInterval) -> DictionaryMerge.ShortcutState {
        DictionaryMerge.ShortcutState(trigger: trigger, phrase: phrase,
                                      tombstoned: tombstoned,
                                      updatedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func phraseFollowsTheNewerSide() {
        let older = shortcut("omw", phrase: "On my way", at: 100)
        let newer = shortcut("omw", phrase: "On my way!", at: 200)
        #expect(DictionaryMerge.merge(local: older, remote: newer)?.phrase == "On my way!")
        #expect(DictionaryMerge.merge(local: newer, remote: older)?.phrase == "On my way!")
    }

    @Test func phraseTieBreaksLexicographically() {
        let a = shortcut("omw", phrase: "On my way", at: 100)
        let b = shortcut("omw", phrase: "on my way", at: 100)
        #expect(DictionaryMerge.merge(local: a, remote: b)?.phrase == "On my way")
        #expect(DictionaryMerge.merge(local: b, remote: a)?.phrase == "On my way")
    }

    @Test func deletionPropagatesViaTombstone() {
        let kept = shortcut("omw", phrase: "On my way!", at: 100)
        let deleted = shortcut("omw", phrase: "On my way!", tombstoned: true, at: 200)
        #expect(DictionaryMerge.merge(local: kept, remote: deleted)?.tombstoned == true)
    }

    @Test func absenceIsNotDeletion() {
        let only = shortcut("brb", phrase: "be right back", at: 100)
        #expect(DictionaryMerge.merge(local: nil, remote: only) == only)
        #expect(DictionaryMerge.merge(local: only, remote: nil) == only)
    }
}
