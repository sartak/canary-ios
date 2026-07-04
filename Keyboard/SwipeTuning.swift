//
//  SwipeTuning.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics
import Foundation

/// Every tunable constant for swipe decoding, in one place.
/// Distances are expressed in key-pitch units (alphaKeyWidth + horizontalGap)
/// unless noted otherwise, so values are device-independent.
/// See swiping.md §5 for rationale; defaults validated by the synthetic
/// accuracy harness (§8.3).
enum SwipeTuning {
    /// Points per resampled polyline (user path and templates).
    static let resampleCount = 64

    /// Radius around the path's start/end within which a key's letter joins
    /// the candidate pruning set. In key-pitch units. Generous by design:
    /// pruning exists for speed, not accuracy.
    static let pruneRadius: CGFloat = 1.6

    /// SQL LIMIT for the final decode's candidate fetch (frequency-ordered,
    /// so anything cut is deep-tail vocabulary).
    static let maxCandidates = 1500

    /// SQL LIMIT for mid-swipe live decodes.
    static let liveCandidates = 300

    /// Candidates whose ideal template arc length differs from the user path
    /// arc length by more than this ratio (either direction) are skipped.
    static let lengthRatioLimit: CGFloat = 2.2

    /// Gaussian sigma for the shape channel, in normalized-bounding-box units.
    static let sigmaShape: CGFloat = 0.35

    /// Gaussian sigma for the location channel, in key-pitch units.
    static let sigmaLocation: CGFloat = 0.8

    /// Exponent on the word prior (gamma): 0 ignores frequency, 1 lets it
    /// steamroll geometry. At 0.4 a 500x rank advantage was worth ~2.5 log
    /// units — more than accurate tracing could overcome — and common words
    /// overmatched; 0.2 halves that.
    static let lmWeight: Double = 0.2

    /// Location-channel weight at the middle of the path; endpoints get 1.0
    /// with a linear ramp between.
    static let midPathWeight: CGFloat = 0.4

    /// Confidence gate: reject the decode entirely when the best candidate
    /// exceeds BOTH of these channel distances.
    static let rejectShape: CGFloat = 0.9
    static let rejectLocation: CGFloat = 2.5

    /// Minimum interval between live decodes during a swipe.
    static let liveDecodeInterval: TimeInterval = 0.060

    /// Template cache entries before wholesale eviction.
    static let templateCacheCapacity = 10_000
}
