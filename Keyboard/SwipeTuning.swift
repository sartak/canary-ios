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
    /// On-device traces score xs <= ~0.1 even for wrong-but-similar words, so
    /// 0.35 left the channel nearly flat.
    static let sigmaShape: CGFloat = 0.25

    /// Gaussian sigma for the location channel, in key-pitch units. Sharpened
    /// twice from 0.8 on on-device evidence: the true word consistently shows
    /// a decisively lower x_l than frequent impostors (0.39 vs 1.09; 0.77 vs
    /// 0.99), and this channel must convert that into rank.
    static let sigmaLocation: CGFloat = 0.5

    /// Exponent on the word prior (gamma): 0 ignores frequency, 1 lets it
    /// steamroll geometry. Lowered twice (0.4 → 0.2 → 0.1) on on-device
    /// evidence of common words outvoting clear geometric verdicts; at 0.1
    /// the prior still decides identical-template pairs (to/too) and is worth
    /// ~0.7 log units across a 1000x rank gap, but no longer beats a
    /// well-traced rarer word.
    static let lmWeight: Double = 0.1

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

    /// Minimum signed turning, in radians (~270°), for a mid-swipe loop to count
    /// as a double-letter signal. Signed accumulation means back-and-forth
    /// wobble cancels rather than accruing (swiping.md §4.10).
    static let loopMinTurn: CGFloat = 4.7

    /// Maximum loop radius, in key-pitch units: the loop must stay this tight
    /// around its centroid to be read as a deliberate circle rather than a
    /// normal cornering of the path.
    static let loopMaxRadius: CGFloat = 0.9

    /// Arc-fraction window for matching a detected loop to a template's doubled
    /// letter (final decodes only; live decodes match on character alone).
    static let loopMatchTolerance: CGFloat = 0.25

    /// Bonus added to a candidate's log score, in log units, for each detected
    /// loop that matches one of its doubled letters. Sized to beat the to/too
    /// prior gap (~0.6 at lmWeight 0.1) so the loop decides that pair.
    static let doubleLetterBonus: Double = 1.0

    /// Minimum turn, in radians (~115°), a reversal apex must reach within at
    /// most two fine-resample vertices to count as a wiggle apex — the natural
    /// back-and-forth double-letter gesture that signed loop accumulation is
    /// blind to (swiping.md §4.10).
    static let wiggleApexTurn: CGFloat = 2.0

    /// Minimum wiggle leg length, in key-pitch units: below this a reversal is
    /// jitter, not a deliberate gesture.
    static let wiggleMinLeg: CGFloat = 0.12

    /// Maximum wiggle leg length, in key-pitch units: above this a reversal is
    /// lexical travel between distinct letters (adjacent keys are >= 1 pitch
    /// apart), not a wiggle on a single key.
    static let wiggleMaxLeg: CGFloat = 0.65

    /// Finalists rescored with banded DTW after the cheap pointwise pass.
    /// Comfortably above the bar's needs (limit is 10) so the returned
    /// prefix always comes from the rescored, comparable set.
    static let dtwRescoreCount = 20

    /// Sakoe-Chiba band half-width for the DTW rescore, in resampled points
    /// (of resampleCount): alignment may flex up to ±band indices, enough to
    /// absorb wobbles and cut corners while keeping degenerate warps (one
    /// word's shape smeared onto a much longer word's) impossible.
    static let dtwBand = 8
}
