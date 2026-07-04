//
//  SwipeTemplate.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics

/// Lowercased character → center of its key, in KeyboardTouchView coordinates.
/// Built from the alpha layer's KeyData.viewFrame midpoints, so templates
/// automatically track the active layout, split, and device geometry.
struct KeyCenters: Equatable {
    let centers: [Character: CGPoint]
}

/// The ideal swipe for a word: the polyline through its letters' key centers
/// (swiping.md §4.3).
struct SwipeTemplate {
    /// Original cased word from the lexicon, for insertion.
    let word: String
    /// Key-center polyline after collapsing consecutive duplicate keys;
    /// unresampled, used for arc-length truncation in live decoding.
    let polyline: [CGPoint]
    /// The polyline resampled to equidistant points for channel scoring.
    let points: [CGPoint]
    /// `points` normalized (centroid at origin, long side = 1) for the
    /// shape channel; precomputed once per template.
    let normalizedPoints: [CGPoint]
    let idealArcLength: CGFloat

    /// Returns nil when the word cannot be expressed as a swipe: after
    /// dropping characters with no key (apostrophes) and collapsing
    /// consecutive duplicates, fewer than two key positions remain.
    static func make(word: String,
                     keyCenters: KeyCenters,
                     resampleCount: Int = SwipeTuning.resampleCount) -> SwipeTemplate? {
        var polyline: [CGPoint] = []
        var lastMapped: Character?
        for character in word.lowercased() {
            guard let center = keyCenters.centers[character] else { continue }
            if character == lastMapped { continue }
            polyline.append(center)
            lastMapped = character
        }

        guard polyline.count >= 2 else { return nil }

        let resampledPoints = PathGeometry.resample(polyline, count: resampleCount)
        return SwipeTemplate(
            word: word,
            polyline: polyline,
            points: resampledPoints,
            normalizedPoints: PathGeometry.normalized(resampledPoints, toSize: 1),
            idealArcLength: PathGeometry.arcLength(polyline)
        )
    }
}

/// Memoizes templates for the current key geometry. Templates are cheap but
/// decoded against hundreds of candidates per swipe; caching keeps repeat
/// swipes allocation-light. Invalidated wholesale when geometry changes
/// (rotation, layout switch) or capacity is exceeded.
final class SwipeTemplateCache {
    private var keyCenters: KeyCenters
    private let resampleCount: Int
    private let capacity: Int
    private var cache: [String: SwipeTemplate?] = [:]

    init(keyCenters: KeyCenters,
         resampleCount: Int = SwipeTuning.resampleCount,
         capacity: Int = SwipeTuning.templateCacheCapacity) {
        self.keyCenters = keyCenters
        self.resampleCount = resampleCount
        self.capacity = capacity
    }

    func updateKeyCenters(_ newCenters: KeyCenters) {
        guard newCenters != keyCenters else { return }
        keyCenters = newCenters
        cache.removeAll(keepingCapacity: true)
    }

    /// Returns the word's template for the current geometry, or nil for
    /// words that cannot be swiped (memoized either way).
    func template(for word: String) -> SwipeTemplate? {
        if let cached = cache[word] {
            return cached
        }
        if cache.count >= capacity {
            cache.removeAll(keepingCapacity: true)
        }
        let template = SwipeTemplate.make(word: word, keyCenters: keyCenters, resampleCount: resampleCount)
        cache[word] = template
        return template
    }
}
