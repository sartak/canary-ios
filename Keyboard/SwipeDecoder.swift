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
    /// Double-letter loop bonus already folded into `logScore`, in log units;
    /// exposed so the breakdown can separate it from the frequency prior
    /// (swiping.md §4.10). Zero when no loop matched this candidate.
    let loopBonus: Double
}

/// Two-channel (shape + location) template scoring with a frequency prior
/// (swiping.md §4.5). A pure decoder: `(path, key centers, pitch) → ranked
/// candidates`. Foundation + CoreGraphics only, so it runs in the test target
/// without UIKit or a device.
final class SwipeDecoder {
    private let lexicon: SwipeLexicon

    /// Personal usage + learned words (Milestone 9 stage 2), set by
    /// `SuggestionService` after construction. Learned words join the candidate
    /// pool and personal counts blend into the frequency prior.
    weak var usageStore: UsageStore?

    /// Per-geometry template memoization, reused across decodes and rebuilt
    /// lazily when key centers change (rotation / layout switch).
    private var cache: SwipeTemplateCache?

    /// log of the lexicon's total occurrence count, normalizing the frequency
    /// prior: log P(w) = log(frequency) − logTotalFrequency. Depends only on
    /// the lexicon, so it is computed once.
    private lazy var logTotalFrequency: Double =
        log(Double(lexicon.totalFrequency))

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

    /// Memory-pressure hook: drops the template cache (worst case ~12MB);
    /// templates rebuild lazily on the next decode. Nil-ing rather than
    /// emptying also releases the dictionary's capacity and the KeyCenters copy.
    func releaseMemory() {
        cache = nil
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
        // Post-threshold swipes always satisfy this; the pure function must
        // still not crash on a degenerate path (swiping.md §7).
        guard path.count >= 2, PathGeometry.arcLength(path) > 0, keyPitch > 0
            else { return [] }

        // Excise any double-letter loops before scoring so they add neither arc
        // length nor location error against the collapsed templates; the matched
        // loop events feed the per-candidate bonus below (swiping.md §4.10).
        let (scoringPath, loopEvents) = loopScoring(path: path, keyCenters: keyCenters,
                                                    keyPitch: keyPitch)
        let userArcLength = PathGeometry.arcLength(scoringPath)
        guard userArcLength > 0, let start = scoringPath.first,
              let end = scoringPath.last else { return [] }

        let cache = templateCache(for: keyCenters)
        let userResampled = PathGeometry.resample(scoringPath, count: SwipeTuning.resampleCount)
        let userNormalized = PathGeometry.normalized(userResampled, toSize: 1)

        let radius = SwipeTuning.pruneRadius * keyPitch
        let startLetters = letters(near: start, in: keyCenters, radius: radius)
        let endLetters = letters(near: end, in: keyCenters, radius: radius)
        let lexiconEntries = lexicon.candidates(startingWith: startLetters,
                                                endingWith: endLetters,
                                                limit: SwipeTuning.maxCandidates)
        let entries = lexiconEntries + learnedEntries(startLetters: startLetters,
                                                      endLetters: endLetters,
                                                      existing: lexiconEntries)

        let (ranked, skipped) = rank(entries: entries, cache: cache,
                                     userResampled: userResampled,
                                     userNormalized: userNormalized,
                                     userArcLength: userArcLength,
                                     keyPitch: keyPitch,
                                     weights: Self.locationWeights,
                                     loopEvents: loopEvents,
                                     limit: limit, live: false)

        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logDecodeBreakdown(ranked, startLetters: startLetters, endLetters: endLetters,
                           userArcLength: userArcLength, keyPitch: keyPitch,
                           candidates: entries.count, skipped: skipped,
                           loopEvents: loopEvents, cache: cache, duration: duration)

        // Confidence gate: reject only when the best candidate is far in BOTH
        // channels — a wildly wrong insertion is worse than none.
        if let best = ranked.first,
           best.shapeDistance > SwipeTuning.rejectShape,
           best.locationDistance > SwipeTuning.rejectLocation {
            print("SwipeDecoder: rejected '\(best.word)' " +
                  "x_s=\(dist(best.shapeDistance)) x_l=\(dist(best.locationDistance))")
            return []
        }

        return ranked
    }

    /// Mid-swipe decode of a partial path (swiping.md §4.7): first-letter
    /// pruning only, templates truncated to the current arc length, endpoint
    /// weighting relaxed, no confidence gate.
    func liveCandidates(path: [CGPoint], keyCenters: KeyCenters, keyPitch: CGFloat,
                        limit: Int = 10) -> [SwipeCandidate] {
        let startTime = CFAbsoluteTimeGetCurrent()
        guard path.count >= 2, PathGeometry.arcLength(path) > 0, keyPitch > 0
            else { return [] }

        // Loops signal doubled letters mid-swipe here too; excise them and match
        // events on character alone (partial-path arc fractions are not directly
        // comparable to the full template's, swiping.md §4.10).
        let (scoringPath, loopEvents) = loopScoring(path: path, keyCenters: keyCenters,
                                                    keyPitch: keyPitch)
        let userArcLength = PathGeometry.arcLength(scoringPath)
        guard userArcLength > 0, let start = scoringPath.first else { return [] }

        let cache = templateCache(for: keyCenters)
        let userResampled = PathGeometry.resample(scoringPath, count: SwipeTuning.resampleCount)
        let userNormalized = PathGeometry.normalized(userResampled, toSize: 1)

        let radius = SwipeTuning.pruneRadius * keyPitch
        let startLetters = letters(near: start, in: keyCenters, radius: radius)
        let lexiconEntries = lexicon.candidates(startingWith: startLetters,
                                                limit: SwipeTuning.liveCandidates)
        let entries = lexiconEntries + learnedEntries(startLetters: startLetters,
                                                      endLetters: nil,
                                                      existing: lexiconEntries)

        let (ranked, skipped) = rank(entries: entries, cache: cache,
                                     userResampled: userResampled,
                                     userNormalized: userNormalized,
                                     userArcLength: userArcLength,
                                     keyPitch: keyPitch,
                                     weights: Self.liveLocationWeights,
                                     loopEvents: loopEvents,
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
                      weights: [CGFloat],
                      loopEvents: [(character: Character, arcFraction: CGFloat)],
                      limit: Int,
                      live: Bool) -> (ranked: [SwipeCandidate], skipped: Int) {
        // Pass-1 winners carry what the DTW rescore needs alongside the
        // pointwise candidate.
        struct Finalist {
            var candidate: SwipeCandidate
            let templatePoints: [CGPoint]
            let templateNormalized: [CGPoint]
            let logPrior: Double
        }

        var scored: [Finalist] = []
        scored.reserveCapacity(entries.count)
        var skipped = 0

        for entry in entries {
            let templates = cache.templates(for: entry.word)
            if templates.isEmpty {
                skipped += 1
                continue
            }

            // Frequency prior: log P(w) = log(count) − log(total), with true
            // counts from the Google Web Trillion Word Corpus. Personal usage
            // adds mass so the user's own vocabulary wins geometric ties
            // (swipe→scope, canary). `personalCount` is a dictionary hit — no SQL
            // — so this stays cheap per candidate; the `lowercased()` allocates,
            // which the design accepts. Clamped against log(0). Template-
            // independent, so computed once per word.
            let personal = usageStore?.personalCount(for: entry.word.lowercased()) ?? 0
            let effectiveCount = entry.frequency + LearningTuning.personalCountBoost * personal
            let logPrior = log(Double(max(effectiveCount, 1))) - logTotalFrequency

            // Apostrophe words carry two template variants (letter-only and
            // through-the-apostrophe); the word scores as its best variant, so
            // a deliberate detour through ' matches the explicit template and
            // beats the plain-word twin.
            var best: Finalist?
            for template in templates {
                // Length pruning. Live keeps long templates (the user may still
                // be mid-word) and drops only those already too short to match.
                if live {
                    if template.idealArcLength < userArcLength / SwipeTuning.lengthRatioLimit {
                        continue
                    }
                } else {
                    let ratio = userArcLength / template.idealArcLength
                    if ratio < 1 / SwipeTuning.lengthRatioLimit || ratio > SwipeTuning.lengthRatioLimit {
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

                // Double-letter loop bonus: each detected loop that matches one of
                // this candidate's doubled letters adds `doubleLetterBonus`. Matched
                // template entries are consumed so two loops can't claim one double;
                // unmatched loops cost nothing (excision already neutralized them).
                // Live decodes match on character only (§4.10).
                var loopBonus = 0.0
                if !loopEvents.isEmpty && !template.doubledLetters.isEmpty {
                    var available = template.doubledLetters
                    for event in loopEvents {
                        if let matchIndex = available.firstIndex(where: { doubled in
                            doubled.character == event.character
                                && (live || abs(doubled.arcFraction - event.arcFraction)
                                            <= SwipeTuning.loopMatchTolerance)
                        }) {
                            loopBonus += SwipeTuning.doubleLetterBonus
                            available.remove(at: matchIndex)
                        }
                    }
                }

                let logScore = -Double(xs * xs) / (2 * Self.sigmaShapeSq)
                    - Double(xl * xl) / (2 * Self.sigmaLocationSq)
                    + SwipeTuning.lmWeight * logPrior
                    + loopBonus

                if best == nil || logScore > best!.candidate.logScore {
                    best = Finalist(
                        candidate: SwipeCandidate(word: entry.word, logScore: logScore,
                                                  shapeDistance: xs, locationDistance: xl,
                                                  loopBonus: loopBonus),
                        templatePoints: templatePoints,
                        templateNormalized: templateNormalized,
                        logPrior: logPrior)
                }
            }

            if let best {
                scored.append(best)
            } else {
                skipped += 1
            }
        }

        // Pass 1 order: the cheap pointwise scores select the finalists.
        // sorted(by:) is not guaranteed stable, and exact score ties are real
        // ("can't" letter-only vs "cant": same path, same corpus count); ties
        // break toward the lexicon's rank order via the index.
        var ordered = scored.enumerated()
            .sorted {
                $0.element.candidate.logScore != $1.element.candidate.logScore
                    ? $0.element.candidate.logScore > $1.element.candidate.logScore
                    : $0.offset < $1.offset
            }
            .map(\.element)

        // Pass 2: banded-DTW rescore of the finalists. Pointwise comparison
        // is index-rigid — one wobbly or corner-cut segment throws every
        // later point off-phase and poisons the tail of the comparison — so
        // the finalists are rescored with an elastic alignment (band-limited;
        // see SwipeTuning.dtwBand) in both channels. Only they pay the
        // O(N·band) cost, and since dtwRescoreCount comfortably exceeds
        // `limit`, the returned prefix always comes from the rescored,
        // mutually comparable set.
        let rescoreCount = min(SwipeTuning.dtwRescoreCount, ordered.count)
        for index in 0..<rescoreCount {
            let finalist = ordered[index]
            let xs = PathGeometry.dtwMeanDistance(userNormalized, finalist.templateNormalized,
                                                  band: SwipeTuning.dtwBand)
            let xl = PathGeometry.dtwWeightedDistance(userResampled, finalist.templatePoints,
                                                      weights: weights,
                                                      band: SwipeTuning.dtwBand) / keyPitch
            let loopBonus = finalist.candidate.loopBonus
            let logScore = -Double(xs * xs) / (2 * Self.sigmaShapeSq)
                - Double(xl * xl) / (2 * Self.sigmaLocationSq)
                + SwipeTuning.lmWeight * finalist.logPrior
                + loopBonus
            ordered[index].candidate = SwipeCandidate(word: finalist.candidate.word,
                                                      logScore: logScore,
                                                      shapeDistance: xs,
                                                      locationDistance: xl,
                                                      loopBonus: loopBonus)
        }

        // Final order among the rescored finalists, same tie-break (identical
        // templates stay identical under DTW, so can't/cant still ties).
        let ranked = Array(ordered.prefix(rescoreCount).enumerated()
            .sorted {
                $0.element.candidate.logScore != $1.element.candidate.logScore
                    ? $0.element.candidate.logScore > $1.element.candidate.logScore
                    : $0.offset < $1.offset
            }
            .map(\.element.candidate)
            .prefix(limit))
        return (ranked, skipped)
    }

    // MARK: - Learned words

    /// Learned words (Milestone 9 stage 2) that survive the same endpoint pruning
    /// as lexicon candidates, as synthetic entries. Endpoints are the first/last
    /// letters of the letters-only lowercased form, mirroring
    /// `build_corpus.swipe_columns`; words with fewer than two distinct
    /// consecutive-collapsed keys are dropped (their template would be nil).
    /// Words already present in `existing` (by lowercased word) are skipped so a
    /// learned word never duplicates its lexicon row.
    private func learnedEntries(startLetters: Set<Character>,
                                endLetters: Set<Character>?,
                                existing: [SwipeLexiconEntry]) -> [SwipeLexiconEntry] {
        guard let store = usageStore else { return [] }
        // Shortcut triggers ride along: swiping o-m-w must be able to decode
        // to "omw" for the expansion hook to fire, and triggers are not in
        // the lexicon. Same synthetic frequency as learned words.
        let words = store.learnedWords() + store.shortcutTriggerWords()
        guard !words.isEmpty else { return [] }

        var seen = Set(existing.map { $0.word.lowercased() })
        var result: [SwipeLexiconEntry] = []
        for word in words {
            let lower = word.lowercased()
            if seen.contains(lower) { continue }

            let letters = lower.filter { $0.isASCII && $0.isLetter }
            guard let first = letters.first, let last = letters.last else { continue }
            guard startLetters.contains(first) else { continue }
            if let endLetters, !endLetters.contains(last) { continue }
            guard Self.hasTwoDistinctKeys(letters) else { continue }

            // Base mass only: the personal-count boost is applied uniformly to
            // every candidate in rank()'s prior blend — baking it in here too
            // would double-count it for learned words.
            result.append(SwipeLexiconEntry(
                word: word, frequencyRank: 0,
                frequency: LearningTuning.learnedWordFrequency))
            seen.insert(lower)
        }
        return result
    }

    /// Whether `letters` (already letters-only) has at least two distinct keys
    /// after collapsing consecutive duplicates — the swipe-decodability floor
    /// (mirrors `SwipeTemplate.make`, which returns nil otherwise).
    private static func hasTwoDistinctKeys(_ letters: String) -> Bool {
        var previous: Character?
        var distinct = 0
        for character in letters where character != previous {
            distinct += 1
            previous = character
            if distinct >= 2 { return true }
        }
        return false
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

    /// Detects double-letter loops on the raw path, maps each to the nearest
    /// key, and excises the loops so the remaining polyline scores like a normal
    /// swipe. Returns the de-looped scoring path and one event per matched loop
    /// (swiping.md §4.10). Falls back to `(path, [])` — no excision, no bonus —
    /// when no loop is found, no loop lands on a key, or excision would collapse
    /// the path (the whole path is one big loop).
    private func loopScoring(path: [CGPoint], keyCenters: KeyCenters, keyPitch: CGFloat)
        -> (scoringPath: [CGPoint], events: [(character: Character, arcFraction: CGFloat)]) {
        let loops = PathGeometry.detectLoops(in: path,
                                             minTurn: SwipeTuning.loopMinTurn,
                                             maxRadius: SwipeTuning.loopMaxRadius * keyPitch)
        // A wiggle — a quick back-and-forth on a key — is the other natural
        // double-letter gesture; signed loop accumulation cancels it, so a
        // separate detector keyed on reversal legs finds it (swiping.md §4.10).
        let wiggles = PathGeometry.detectWiggles(in: path,
                                                 apexTurn: SwipeTuning.wiggleApexTurn,
                                                 minLeg: SwipeTuning.wiggleMinLeg * keyPitch,
                                                 maxLeg: SwipeTuning.wiggleMaxLeg * keyPitch)
        // Merge: keep every loop, then add each wiggle whose arc-range does NOT
        // overlap any loop's. A small circle can trip both detectors — the loop
        // wins, so one gesture never yields two events/bonuses. Loops are
        // mutually non-overlapping and so are wiggles, so the result is too.
        var merged = loops
        for wiggle in wiggles where !loops.contains(where: {
            wiggle.arcStart <= $0.arcEnd && $0.arcStart <= wiggle.arcEnd
        }) {
            merged.append(wiggle)
        }
        guard !merged.isEmpty else { return (path, []) }

        let radius = SwipeTuning.pruneRadius * keyPitch
        var matched: [(loop: PathLoop, character: Character)] = []
        for loop in merged {
            if let character = nearestLetter(to: loop.centroid, in: keyCenters, within: radius) {
                matched.append((loop: loop, character: character))
            }
        }
        guard !matched.isEmpty else { return (path, []) }

        let sorted = matched.sorted { $0.loop.arcStart < $1.loop.arcStart }
        let ranges = sorted.map { (start: $0.loop.arcStart, end: $0.loop.arcEnd) }
        let excised = PathGeometry.excising(path, arcRanges: ranges)
        // Nothing removed (excision would leave < 2 points, so it was skipped):
        // treat as no loops — neither excise nor award a bonus.
        guard excised.count < path.count else { return (path, []) }

        // Event positions are matched against template arc fractions, which are
        // loop-free by construction — so measure each loop's ENTRY point on the
        // de-looped path: subtract the spans of earlier excised loops, normalize
        // by the excised total. (The raw-path fraction is systematically low: a
        // trailing loop's own circumference inflates the denominator, putting a
        // final-letter double at ~0.7 instead of 1.0.)
        let excisedTotal = PathGeometry.arcLength(excised)
        guard excisedTotal > 0 else { return (path, []) }
        var removedBefore: CGFloat = 0
        var events: [(character: Character, arcFraction: CGFloat)] = []
        for item in sorted {
            let adjusted = (item.loop.arcStart - removedBefore) / excisedTotal
            events.append((character: item.character,
                           arcFraction: min(max(adjusted, 0), 1)))
            removedBefore += item.loop.arcEnd - item.loop.arcStart
        }
        return (excised, events)
    }

    /// The character whose key center is nearest `point`, within `radius`, or
    /// nil if none is that close — maps a loop centroid to the key it circles.
    private func nearestLetter(to point: CGPoint, in keyCenters: KeyCenters,
                               within radius: CGFloat) -> Character? {
        var best: Character?
        var bestDistance = radius
        for (character, center) in keyCenters.centers {
            let dx = center.x - point.x
            let dy = center.y - point.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= bestDistance {
                bestDistance = d
                best = character
            }
        }
        return best
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

    /// Per-candidate scoring breakdown for final decodes, for tuning from the
    /// console: which stage lost the intended word (absent from the top 5 →
    /// pruning; present but beaten → the term in parentheses that lost it).
    private func logDecodeBreakdown(_ ranked: [SwipeCandidate],
                                    startLetters: Set<Character>, endLetters: Set<Character>,
                                    userArcLength: CGFloat, keyPitch: CGFloat,
                                    candidates: Int, skipped: Int,
                                    loopEvents: [(character: Character, arcFraction: CGFloat)],
                                    cache: SwipeTemplateCache,
                                    duration: Double) {
        let pitches = Double(userArcLength / keyPitch)
        let loopStr = loopEvents.isEmpty ? "" :
            " loops=[" + loopEvents.map {
                "\($0.character)@" + String(format: "%.2f", Double($0.arcFraction))
            }.joined(separator: ",") + "]"
        print("SwipeDecoder: start={\(String(startLetters.sorted()))} " +
              "end={\(String(endLetters.sorted()))} " +
              "len=\(String(format: "%.1f", pitches)) pitches, " +
              "\(candidates) candidates, \(skipped) skipped, in \(ms(duration))ms" + loopStr)
        for (index, candidate) in ranked.prefix(5).enumerated() {
            let shapeTerm = -Double(candidate.shapeDistance * candidate.shapeDistance)
                / (2 * Self.sigmaShapeSq)
            let locationTerm = -Double(candidate.locationDistance * candidate.locationDistance)
                / (2 * Self.sigmaLocationSq)
            let priorTerm = candidate.logScore - shapeTerm - locationTerm - candidate.loopBonus
            var loopTerm = candidate.loopBonus != 0
                ? String(format: " loop(%+.2f)", candidate.loopBonus) : ""
            // When loops were detected, show where each candidate's doubled
            // letters sit so match/no-match is diagnosable from one line.
            if !loopEvents.isEmpty,
               let doubled = cache.templates(for: candidate.word).first?.doubledLetters,
               !doubled.isEmpty {
                loopTerm += " dbl=[" + doubled.map {
                    "\($0.character)@" + String(format: "%.2f", Double($0.arcFraction))
                }.joined(separator: ",") + "]"
            }
            print(String(format: "SwipeDecoder:   %d. '%@' xs=%.2f (%+.2f) xl=%.2f (%+.2f) prior (%+.2f)%@ = %+.2f",
                         index + 1, candidate.word,
                         Double(candidate.shapeDistance), shapeTerm,
                         Double(candidate.locationDistance), locationTerm,
                         priorTerm, loopTerm, candidate.logScore))
        }
    }

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
