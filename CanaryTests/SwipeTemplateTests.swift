//
//  SwipeTemplateTests.swift
//  CanaryTests
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics
import Testing

/// Letters on a simple 10pt grid; only what the tests need.
private let gridCenters = KeyCenters(centers: [
    "h": CGPoint(x: 0, y: 0),
    "e": CGPoint(x: 10, y: 0),
    "l": CGPoint(x: 20, y: 0),
    "o": CGPoint(x: 30, y: 0),
    "d": CGPoint(x: 0, y: 10),
    "n": CGPoint(x: 10, y: 10),
    "t": CGPoint(x: 20, y: 10),
    "a": CGPoint(x: 30, y: 10),
])

struct SwipeTemplateTests {
    @Test func polylinePassesThroughKeyCenters() {
        let template = SwipeTemplate.make(word: "hen", keyCenters: gridCenters)
        #expect(template?.polyline == [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10),
        ])
    }

    @Test func consecutiveDuplicateLettersCollapse() {
        let template = SwipeTemplate.make(word: "hello", keyCenters: gridCenters)
        #expect(template?.polyline == [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0),
        ])
        #expect(template?.idealArcLength == 30)
    }

    @Test func apostrophesAreDropped() {
        let withApostrophe = SwipeTemplate.make(word: "don't", keyCenters: gridCenters)
        let without = SwipeTemplate.make(word: "dont", keyCenters: gridCenters)
        #expect(withApostrophe?.polyline == without?.polyline)
    }

    @Test func repeatedLetterAcrossDroppedCharacterCollapses() {
        // After dropping the apostrophe the two l's become adjacent; a swipe
        // cannot express the repeat, so this word has one distinct key.
        #expect(SwipeTemplate.make(word: "l'l", keyCenters: gridCenters) == nil)
    }

    @Test func fewerThanTwoDistinctKeysIsNotSwipeable() {
        #expect(SwipeTemplate.make(word: "a", keyCenters: gridCenters) == nil)
        #expect(SwipeTemplate.make(word: "aa", keyCenters: gridCenters) == nil)
        #expect(SwipeTemplate.make(word: "qqq", keyCenters: gridCenters) == nil)
        #expect(SwipeTemplate.make(word: "", keyCenters: gridCenters) == nil)
    }

    @Test func nonConsecutiveRepeatsAreKept() {
        let template = SwipeTemplate.make(word: "onto", keyCenters: gridCenters)
        #expect(template?.polyline.count == 4)
    }

    @Test func mappingIsCaseInsensitiveButWordIsPreserved() {
        let upper = SwipeTemplate.make(word: "Hello", keyCenters: gridCenters)
        let lower = SwipeTemplate.make(word: "hello", keyCenters: gridCenters)
        #expect(upper?.polyline == lower?.polyline)
        #expect(upper?.word == "Hello")
    }

    @Test func pointsAreResampledWithPreservedEndpoints() throws {
        let template = SwipeTemplate.make(word: "hat", keyCenters: gridCenters, resampleCount: 16)
        let points = try #require(template?.points)
        #expect(points.count == 16)
        #expect(points.first == CGPoint(x: 0, y: 0))
        #expect(abs(points.last!.x - 20) <= 1e-3)
        #expect(abs(points.last!.y - 10) <= 1e-3)
    }
}

struct SwipeTemplateCacheTests {
    @Test func returnsSameResultAsDirectConstruction() {
        let cache = SwipeTemplateCache(keyCenters: gridCenters)
        let direct = SwipeTemplate.make(word: "hello", keyCenters: gridCenters)
        #expect(cache.template(for: "hello")?.polyline == direct?.polyline)
        #expect(cache.template(for: "qqq") == nil)
    }

    @Test func geometryChangeInvalidatesCachedTemplates() {
        let cache = SwipeTemplateCache(keyCenters: gridCenters)
        #expect(cache.template(for: "he")?.polyline.last == CGPoint(x: 10, y: 0))

        var moved = gridCenters.centers
        moved["e"] = CGPoint(x: 99, y: 99)
        cache.updateKeyCenters(KeyCenters(centers: moved))
        #expect(cache.template(for: "he")?.polyline.last == CGPoint(x: 99, y: 99))
    }

    @Test func unchangedGeometryKeepsServingTemplates() {
        let cache = SwipeTemplateCache(keyCenters: gridCenters)
        let before = cache.template(for: "hello")
        cache.updateKeyCenters(gridCenters)
        #expect(cache.template(for: "hello")?.polyline == before?.polyline)
    }

    @Test func exceedingCapacityStillReturnsCorrectTemplates() {
        let cache = SwipeTemplateCache(keyCenters: gridCenters, capacity: 2)
        for word in ["hello", "hat", "onto", "hen", "dot"] {
            #expect(cache.template(for: word)?.word == word)
        }
        #expect(cache.template(for: "hello")?.polyline.count == 4)
    }
}
