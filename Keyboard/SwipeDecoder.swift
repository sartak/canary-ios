//
//  SwipeDecoder.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics
import Foundation

/// One scored candidate word for a swipe. Distances are exposed for the debug
/// overlay and tests (swiping.md §4.5).
struct SwipeCandidate {
    /// Original cased word from the lexicon, ready for insertion.
    let word: String
    /// Combined log posterior (higher is better); relative, not a probability.
    let logScore: Double
    /// Shape-channel distance x_s, in normalized-box units (long side = 1).
    let shapeDistance: CGFloat
    /// Location-channel distance x_l, in key-pitch units.
    let locationDistance: CGFloat
}

/// Two-channel (shape + location) template scoring with a frequency prior
/// (swiping.md §4.5). A pure decoder: `(path, key centers, pitch) → ranked
/// candidates`. Foundation + CoreGraphics only, so it runs in the test target
/// without UIKit or a device.
final class SwipeDecoder {
    private let lexicon: SwipeLexicon

    /// Per-geometry template memoization, reused across decodes and rebuilt
    /// lazily when key centers change (rotation / layout switch).
    private var cache: SwipeTemplateCache?

    /// log(H_N) where H_N ≈ ln(N) + γ (Euler–Mascheroni) is the harmonic
    /// number normalizing the Zipf prior. Depends only on the lexicon size,
    /// so it is computed once. N is clamped to ≥ 2 to keep the log positive.
    private lazy var logHarmonic: Double =
        log(log(Double(max(lexicon.wordCount, 2))) + 0.5772156649)

    // Squared Gaussian sigmas, precomputed in Double (score is in log space).
    private static let sigmaShapeSq = Double(SwipeTuning.sigmaShape) * Double(SwipeTuning.sigmaShape)
    private static let sigmaLocationSq = Double(SwipeTuning.sigmaLocation) * Double(SwipeTuning.sigmaLocation)

    /// Location-channel weights for a committed endpoint (final decode):
    /// 1.0 at both ends ramping to `midPathWeight` at the middle, normalized
    /// to sum to 1. Depends only on `resampleCount`, so it is computed once.
    private static let locationWeights = makeWeights(count: SwipeTuning.resampleCount, capTail: false)

    /// Location-channel weights for an uncommitted endpoint (live decode):
    /// the same ramp with the tail half flat-capped at `midPathWeight`, so the
    /// not-yet-drawn end point is not up-weighted (swiping.md §4.7).
    private static let liveLocationWeights = makeWeights(count: SwipeTuning.resampleCount, capTail: true)

    init(lexicon: SwipeLexicon) {
        self.lexicon = lexicon
    }

    /// Full decode on touch-up. Returns ranked candidates, best first, or `[]`
    /// when the confidence gate rejects (swiping.md §4.5).
    /// - Parameters:
    ///   - path: user path in KeyboardTouchView coordinates.
    ///   - keyCenters: alpha-layer key centers in the same coordinates.
    ///   - keyPitch: alphaKeyWidth + horizontalGap; the location-channel unit.
    ///   - limit: maximum candidates returned.
    func decode(path: [CGPoint], keyCenters: KeyCenters, keyPitch: CGFloat,
                limit: Int = 10) -> [SwipeCandidate] {
        let startTime = CFAbsoluteTimeGetCurrent()
        let userArcLength = PathGeometry.arcLength(path)
        // Post-threshold swipes always satisfy this; the pure function must
        // still not crash on a degenerate path (swiping.md §7).
        guard path.count >= 2, userArcLength > 0, keyPitch > 0,
              let start = path.first, let end = path.last else { return [] }

        let cache = templateCache(for: keyCenters)
        let userResampled = PathGeometry.resample(path, count: SwipeTuning.resampleCount)
        let userNormalized = PathGeometry.normalized(userResampled, toSize: 1)

        let radius = SwipeTuning.pruneRadius * keyPitch
        let startLetters = letters(near: start, in: keyCenters, radius: radius)
        let endLetters = letters(near: end, in: keyCenters, radius: radius)
        let entries = lexicon.candidates(startingWith: startLetters,
                                         endingWith: endLetters,
                                         limit: SwipeTuning.maxCandidates)

        let (ranked, skipped) = rank(entries: entries, cache: cache,
                                     userResampled: userResampled,
                                     userNormalized: userNormalized,
                                     userArcLength: userArcLength,
                                     keyPitch: keyPitch,
                                     weights: Self.locationWeights,
                                     limit: limit, live: false)

        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // Confidence gate: reject only when the best candidate is far in BOTH
        // channels — a wildly wrong insertion is worse than none.
        if let best = ranked.first,
           best.shapeDistance > SwipeTuning.rejectShape,
           best.locationDistance > SwipeTuning.rejectLocation {
            print("SwipeDecoder: rejected '\(best.word)' " +
                  "x_s=\(dist(best.shapeDistance)) x_l=\(dist(best.locationDistance)) " +
                  "(\(entries.count) candidates, \(skipped) skipped) in \(ms(duration))ms")
            return []
        }

        logRanked(ranked, prefix: "SwipeDecoder", candidates: entries.count,
                  skipped: skipped, duration: duration)
        return ranked
    }

    /// Mid-swipe decode of a partial path (swiping.md §4.7): first-letter
    /// pruning only, templates truncated to the current arc length, endpoint
    /// weighting relaxed, no confidence gate.
    func liveCandidates(path: [CGPoint], keyCenters: KeyCenters, keyPitch: CGFloat,
                        limit: Int = 10) -> [SwipeCandidate] {
        let startTime = CFAbsoluteTimeGetCurrent()
        let userArcLength = PathGeometry.arcLength(path)
        guard path.count >= 2, userArcLength > 0, keyPitch > 0,
              let start = path.first else { return [] }

        let cache = templateCache(for: keyCenters)
        let userResampled = PathGeometry.resample(path, count: SwipeTuning.resampleCount)
        let userNormalized = PathGeometry.normalized(userResampled, toSize: 1)

        let radius = SwipeTuning.pruneRadius * keyPitch
        let startLetters = letters(near: start, in: keyCenters, radius: radius)
        let entries = lexicon.candidates(startingWith: startLetters,
                                         limit: SwipeTuning.liveCandidates)

        let (ranked, skipped) = rank(entries: entries, cache: cache,
                                     userResampled: userResampled,
                                     userNormalized: userNormalized,
                                     userArcLength: userArcLength,
                                     keyPitch: keyPitch,
                                     weights: Self.liveLocationWeights,
                                     limit: limit, live: true)

        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logRanked(ranked, prefix: "SwipeDecoder live", candidates: entries.count,
                  skipped: skipped, duration: duration)
        return ranked
    }

    // MARK: - Scoring core

    /// Scores every candidate that survives length pruning and returns the top
    /// `limit` by descending log score, plus the number skipped (unswipeable
    /// or length-pruned). Shared by decode and live; `live` selects truncated
    /// templates and the relaxed length rule (swiping.md §4.4–4.7).
    private func rank(entries: [SwipeLexiconEntry], cache: SwipeTemplateCache,
                      userResampled: [CGPoint], userNormalized: [CGPoint],
                      userArcLength: CGFloat, keyPitch: CGFloat,
                      weights: [CGFloat], limit: Int,
                      live: Bool) -> (ranked: [SwipeCandidate], skipped: Int) {
        var scored: [SwipeCandidate] = []
        scored.reserveCapacity(entries.count)
        var skipped = 0

        for entry in entries {
            guard let template = cache.template(for: entry.word) else {
                skipped += 1
                continue
            }

            // Length pruning. Live keeps long templates (the user may still be
            // mid-word) and drops only those already too short to still match.
            if live {
                if template.idealArcLength < userArcLength / SwipeTuning.lengthRatioLimit {
                    skipped += 1
                    continue
                }
            } else {
                let ratio = userArcLength / template.idealArcLength
                if ratio < 1 / SwipeTuning.lengthRatioLimit || ratio > SwipeTuning.lengthRatioLimit {
                    skipped += 1
                    continue
                }
            }

            // For a live prefix, compare against the template truncated to the
            // arc length drawn so far; otherwise use the precomputed full word.
            let templatePoints: [CGPoint]
            let templateNormalized: [CGPoint]
            if live && userArcLength < template.idealArcLength {
                let head = PathGeometry.truncated(template.polyline, atArcLength: userArcLength)
                let resampled = PathGeometry.resample(head, count: SwipeTuning.resampleCount)
                templatePoints = resampled
                templateNormalized = PathGeometry.normalized(resampled, toSize: 1)
            } else {
                templatePoints = template.points
                templateNormalized = template.normalizedPoints
            }

            let xs = PathGeometry.meanPointwiseDistance(userNormalized, templateNormalized)
            let xl = PathGeometry.weightedPointwiseDistance(userResampled, templatePoints,
                                                            weights: weights) / keyPitch

            // Zipf prior: log P(w) = −log(rank) − log(H_N). rank ≥ 1 always
            // holds for frequency_rank; clamp defensively against log(0).
            let logPrior = -log(Double(max(entry.frequencyRank, 1))) - logHarmonic
            let logScore = -Double(xs * xs) / (2 * Self.sigmaShapeSq)
                - Double(xl * xl) / (2 * Self.sigmaLocationSq)
                + SwipeTuning.lmWeight * logPrior

            scored.append(SwipeCandidate(word: entry.word, logScore: logScore,
                                         shapeDistance: xs, locationDistance: xl))
        }

        let ranked = Array(scored.sorted { $0.logScore > $1.logScore }.prefix(limit))
        return (ranked, skipped)
    }

    // MARK: - Geometry / cache helpers

    /// Returns the cache for `keyCenters`, creating it on first use or letting
    /// it self-invalidate when geometry changed (the equality check is cheap).
    private func templateCache(for keyCenters: KeyCenters) -> SwipeTemplateCache {
        if let cache {
            cache.updateKeyCenters(keyCenters)
            return cache
        }
        let created = SwipeTemplateCache(keyCenters: keyCenters)
        cache = created
        return created
    }

    /// Letters whose key center lies within `radius` (key-pitch × pruneRadius)
    /// of `point` — the spatial pruning set (swiping.md §4.4).
    private func letters(near point: CGPoint, in keyCenters: KeyCenters,
                         radius: CGFloat) -> Set<Character> {
        var result: Set<Character> = []
        for (character, center) in keyCenters.centers {
            let dx = center.x - point.x
            let dy = center.y - point.y
            if (dx * dx + dy * dy).squareRoot() <= radius {
                result.insert(character)
            }
        }
        return result
    }

    // MARK: - Diagnostics

    private func logRanked(_ ranked: [SwipeCandidate], prefix: String,
                           candidates: Int, skipped: Int, duration: Double) {
        if let best = ranked.first {
            print("\(prefix): '\(best.word)' + \(ranked.count - 1) more " +
                  "(\(candidates) candidates, \(skipped) skipped) in \(ms(duration))ms")
        } else {
            print("\(prefix): no match (\(candidates) candidates, \(skipped) skipped) in \(ms(duration))ms")
        }
    }

    private func ms(_ value: Double) -> String { String(format: "%.1f", value) }
    private func dist(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }

    /// Builds the location-channel weight ramp: 1.0 at both endpoints falling
    /// linearly to `midPathWeight` at the middle, then normalized to sum to 1.
    /// When `capTail`, the tail half (indices ≥ count/2) is flat-capped at
    /// `midPathWeight` before normalizing (live decode, uncommitted endpoint).
    private static func makeWeights(count: Int, capTail: Bool) -> [CGFloat] {
        guard count > 1 else { return count == 1 ? [1] : [] }
        let half = CGFloat(count) / 2
        var weights = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            let edge = CGFloat(min(i, count - 1 - i))
            let t = min(edge / half, 1)                       // 0 at ends → 1 mid
            var weight = 1 + (SwipeTuning.midPathWeight - 1) * t
            if capTail && i >= count / 2 {
                weight = min(weight, SwipeTuning.midPathWeight)
            }
            weights[i] = weight
        }
        let sum = weights.reduce(0, +)
        return sum > 0 ? weights.map { $0 / sum } : weights
    }
}
