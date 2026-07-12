//
//  SwipeTemplate.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics

/// Lowercased character → center of its key, in KeyboardTouchView
/// coordinates. Built from the alpha layer's KeyData.viewFrame midpoints, so
/// templates automatically track the active layout, split, and device
/// geometry. Letters plus the apostrophe, by contract — the apostrophe is an
/// optional swipe target for contractions (see SwipeTemplateCache) — and the
/// builder records it under its unshifted identity so shift (' → ") cannot
/// change the centers. Other punctuation must not enter templates.
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
    /// Letters doubled in the word ("too" → o), with the arc fraction (0…1) of
    /// the doubled key along the template polyline. Loops detected in the user
    /// path are matched against these (swiping.md §4.10). Empty for words with
    /// no doubled letters.
    let doubledLetters: [(character: Character, arcFraction: CGFloat)]

    /// Returns nil when the word cannot be expressed as a swipe: after
    /// dropping characters with no key (apostrophes) and collapsing
    /// consecutive duplicates, fewer than two key positions remain.
    static func make(word: String,
                     keyCenters: KeyCenters,
                     resampleCount: Int = SwipeTuning.resampleCount) -> SwipeTemplate? {
        var polyline: [CGPoint] = []
        // Doubled letters recorded as (character, polyline vertex index of the
        // single surviving key point); converted to arc fractions below.
        var doubledIndices: [(character: Character, vertex: Int)] = []
        var lastMapped: Character?
        for character in word.lowercased() {
            guard let center = keyCenters.centers[character] else { continue }
            if character == lastMapped {
                // Collapsed duplicate: its point is the vertex just appended.
                doubledIndices.append((character: character, vertex: polyline.count - 1))
                continue
            }
            polyline.append(center)
            lastMapped = character
        }

        guard polyline.count >= 2 else { return nil }

        // Cumulative arc length at each vertex, to place doubled letters as a
        // fraction of the total (total > 0 since polyline.count >= 2 and the
        // collapse guarantees consecutive vertices are distinct keys).
        let total = PathGeometry.arcLength(polyline)
        var cumulative = [CGFloat](repeating: 0, count: polyline.count)
        for i in 1..<polyline.count {
            let dx = polyline[i].x - polyline[i - 1].x
            let dy = polyline[i].y - polyline[i - 1].y
            cumulative[i] = cumulative[i - 1] + (dx * dx + dy * dy).squareRoot()
        }
        let doubledLetters: [(character: Character, arcFraction: CGFloat)] =
            doubledIndices.map { entry in
                (character: entry.character,
                 arcFraction: total > 0 ? cumulative[entry.vertex] / total : 0)
            }

        let resampledPoints = PathGeometry.resample(polyline, count: resampleCount)
        return SwipeTemplate(
            word: word,
            polyline: polyline,
            points: resampledPoints,
            normalizedPoints: PathGeometry.normalized(resampledPoints, toSize: 1),
            idealArcLength: total,
            doubledLetters: doubledLetters
        )
    }
}

/// Memoizes templates for the current key geometry. Templates are cheap but
/// decoded against hundreds of candidates per swipe; caching keeps repeat
/// swipes allocation-light. Invalidated wholesale when geometry changes
/// (rotation, layout switch) or capacity is exceeded.
///
/// Apostrophe words get up to TWO templates: the letter-only path (the
/// natural swipe — most users never visit the apostrophe key) and a variant
/// traveling through the apostrophe key, so a deliberate detour is an
/// unambiguous "I mean the contraction" that beats the plain-word twin
/// ("we're" vs "were") instead of losing to its higher prior. The decoder
/// scores every variant and keeps the best.
final class SwipeTemplateCache {
    private var keyCenters: KeyCenters
    /// `keyCenters` without the apostrophe, for the letter-only variant.
    private var letterCenters: KeyCenters
    private let resampleCount: Int
    private let capacity: Int
    private var cache: [String: [SwipeTemplate]] = [:]

    init(keyCenters: KeyCenters,
         resampleCount: Int = SwipeTuning.resampleCount,
         capacity: Int = SwipeTuning.templateCacheCapacity) {
        self.keyCenters = keyCenters
        self.letterCenters = Self.lettersOnly(keyCenters)
        self.resampleCount = resampleCount
        self.capacity = capacity
    }

    func updateKeyCenters(_ newCenters: KeyCenters) {
        guard newCenters != keyCenters else { return }
        keyCenters = newCenters
        letterCenters = Self.lettersOnly(newCenters)
        cache.removeAll(keepingCapacity: true)
    }

    /// The word's template variants for the current geometry, best-effort:
    /// letter-only first, then (for apostrophe words, when the layout has an
    /// apostrophe key) the apostrophe-explicit variant. Empty for words that
    /// cannot be swiped (memoized either way).
    func templates(for word: String) -> [SwipeTemplate] {
        if let cached = cache[word] {
            return cached
        }
        if cache.count >= capacity {
            cache.removeAll(keepingCapacity: true)
        }
        var variants: [SwipeTemplate] = []
        if let letters = SwipeTemplate.make(word: word, keyCenters: letterCenters,
                                            resampleCount: resampleCount) {
            variants.append(letters)
        }
        if word.contains("'"), keyCenters.centers["'"] != nil,
           let explicit = SwipeTemplate.make(word: word, keyCenters: keyCenters,
                                             resampleCount: resampleCount) {
            variants.append(explicit)
        }
        cache[word] = variants
        return variants
    }

    private static func lettersOnly(_ centers: KeyCenters) -> KeyCenters {
        KeyCenters(centers: centers.centers.filter { $0.key.isLetter })
    }
}
