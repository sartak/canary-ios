//
//  PathGeometry.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics
import Foundation

/// A detected small loop in a swipe path: the path turns through at least
/// `minTurn` radians (signed, so wobble cancels) while staying within
/// `maxRadius` of the window's centroid. Ranges are expressed as arc lengths
/// so callers can excise them without any resampled-to-original index mapping
/// (swiping.md §4.10).
struct PathLoop {
    /// Arc length (from the path start) at the loop's entry point.
    let arcStart: CGFloat
    /// Arc length (from the path start) at the loop's exit point.
    let arcEnd: CGFloat
    /// Centroid of the loop's points, in the input path's coordinates.
    let centroid: CGPoint
    /// Loop midpoint's arc length / total arc length, in 0…1.
    let arcFraction: CGFloat
}

/// Pure polyline geometry for swipe decoding (swiping.md §4.2).
/// No UIKit, no state — everything here is unit-testable off-device.
enum PathGeometry {
    private static let degenerateEpsilon: CGFloat = 1e-6

    /// Total arc length of a polyline.
    static func arcLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += distance(points[i - 1], points[i])
        }
        return total
    }

    /// Resamples a polyline to `count` points spaced equally by arc length,
    /// preserving both endpoints. A single input point (or zero-length path)
    /// repeats `count` times.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        guard let first = points.first else { return [] }
        guard count > 1 else { return [first] }

        let total = arcLength(points)
        guard total > degenerateEpsilon else {
            return Array(repeating: first, count: count)
        }

        let interval = total / CGFloat(count - 1)
        var result = [first]
        var accumulated: CGFloat = 0
        var previous = first
        var index = 1

        while index < points.count {
            let point = points[index]
            let segment = distance(previous, point)
            if segment > 0 && accumulated + segment >= interval {
                // The next sample falls within this segment; emit it and
                // continue measuring from the sample point.
                let t = (interval - accumulated) / segment
                let sample = CGPoint(
                    x: previous.x + t * (point.x - previous.x),
                    y: previous.y + t * (point.y - previous.y)
                )
                result.append(sample)
                previous = sample
                accumulated = 0
            } else {
                accumulated += segment
                previous = point
                index += 1
            }
        }

        // Floating-point drift can leave the final sample unemitted.
        while result.count < count {
            result.append(points[points.count - 1])
        }
        return Array(result.prefix(count))
    }

    /// Returns the leading portion of a polyline with the given arc length,
    /// interpolating the final point mid-segment. Lengths beyond the path
    /// return the whole path; zero or negative lengths return just the start.
    static func truncated(_ points: [CGPoint], atArcLength length: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        guard length > 0 else { return [first] }

        var result = [first]
        var remaining = length
        for i in 1..<points.count {
            let previous = points[i - 1]
            let point = points[i]
            let segment = distance(previous, point)
            if segment >= remaining {
                if segment > 0 && remaining > 0 {
                    let t = remaining / segment
                    let end = CGPoint(
                        x: previous.x + t * (point.x - previous.x),
                        y: previous.y + t * (point.y - previous.y)
                    )
                    result.append(end)
                }
                return result
            }
            remaining -= segment
            result.append(point)
        }
        return result
    }

    /// Translates the centroid to the origin and scales so the longer
    /// bounding-box side equals `size`, preserving aspect ratio. Degenerate
    /// point clouds (bounding box under epsilon) are translated only.
    static func normalized(_ points: [CGPoint], toSize size: CGFloat) -> [CGPoint] {
        guard !points.isEmpty else { return [] }

        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        var sumX: CGFloat = 0, sumY: CGFloat = 0
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
            sumX += point.x
            sumY += point.y
        }

        let longSide = max(maxX - minX, maxY - minY)
        let scale = longSide > degenerateEpsilon ? size / longSide : 1
        let centroid = CGPoint(x: sumX / CGFloat(points.count), y: sumY / CGFloat(points.count))

        return points.map { point in
            CGPoint(x: (point.x - centroid.x) * scale, y: (point.y - centroid.y) * scale)
        }
    }

    /// Mean pointwise Euclidean distance between two equal-length point arrays.
    static func meanPointwiseDistance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        precondition(a.count == b.count, "point arrays must be equal length")
        guard !a.isEmpty else { return 0 }
        var total: CGFloat = 0
        for i in 0..<a.count {
            total += distance(a[i], b[i])
        }
        return total / CGFloat(a.count)
    }

    /// Weighted pointwise distance Σ wᵢ·‖aᵢ−bᵢ‖. Callers supply weights that
    /// sum to 1 for a weighted mean.
    static func weightedPointwiseDistance(_ a: [CGPoint], _ b: [CGPoint], weights: [CGFloat]) -> CGFloat {
        precondition(a.count == b.count && a.count == weights.count,
                     "point arrays and weights must be equal length")
        var total: CGFloat = 0
        for i in 0..<a.count {
            total += weights[i] * distance(a[i], b[i])
        }
        return total
    }

    /// Detects small loops the user draws to signal a doubled letter
    /// (swiping.md §4.10). Works on a lightly resampled copy (spacing ≈
    /// `maxRadius / 3`) for stable direction vectors. Each candidate window
    /// grows until its points no longer fit within `maxRadius` of their
    /// centroid; if its signed turning reaches `minTurn`, the window is then
    /// tightened from the front (dropping the near-straight approach that
    /// would drag the centroid and entry position off the looped key) and
    /// recorded. Ranges are returned as arc lengths
    /// (invariant between the resampled copy and the original, since resampling
    /// follows the same polyline), so `excising` needs no index mapping.
    /// Degenerate paths (< 4 points or zero arc length) return `[]`. Multiple
    /// loops per path are supported ("committee").
    static func detectLoops(in points: [CGPoint], minTurn: CGFloat, maxRadius: CGFloat) -> [PathLoop] {
        guard points.count >= 4, maxRadius > degenerateEpsilon else { return [] }
        let total = arcLength(points)
        guard total > degenerateEpsilon else { return [] }

        // Resample for stable angles: spacing ≈ maxRadius / 3, with a floor so
        // very short paths still have enough vertices to turn through minTurn.
        let spacing = maxRadius / 3
        let count = max(Int((total / spacing).rounded()) + 1, 8)
        let path = resample(points, count: count)
        guard path.count >= 4 else { return [] }
        let step = total / CGFloat(path.count - 1)   // arc length between vertices

        // Direction of each segment; resampling guarantees equal, nonzero
        // segment lengths, so every angle is well defined.
        let segmentCount = path.count - 1
        var angles = [CGFloat](repeating: 0, count: segmentCount)
        for i in 0..<segmentCount {
            angles[i] = atan2(path[i + 1].y - path[i].y, path[i + 1].x - path[i].x)
        }
        // Signed turn between segment i and segment i+1.
        func turn(_ i: Int) -> CGFloat { wrapAngle(angles[i + 1] - angles[i]) }

        var loops: [PathLoop] = []
        var start = 0   // first segment of the candidate window
        while start < segmentCount {
            // Grow the window [start ... end] (points start ... end+1) segment
            // by segment while all its points stay within maxRadius of their
            // centroid, accumulating signed turning. Growing to the radius
            // break (rather than stopping at minTurn) captures the whole
            // circle, not just its first 270°.
            var end = start
            var cumulative: CGFloat = 0
            while end + 1 < segmentCount {
                if windowRadius(path, start, end + 2).maxDistance > maxRadius {
                    break
                }
                cumulative += turn(end)
                end += 1
            }

            if abs(cumulative) >= minTurn {
                // Tighten from the front: the straight approach into the loop
                // contributes ~no turn but drags the centroid off the looped
                // key and the entry position back along the path. Drop leading
                // segments while the window still meets the threshold.
                var tightStart = start
                var tightTurn = cumulative
                while tightStart < end {
                    let without = tightTurn - turn(tightStart)
                    guard abs(without) >= minTurn else { break }
                    tightTurn = without
                    tightStart += 1
                }

                let arcStart = CGFloat(tightStart) * step
                let arcEnd = CGFloat(end + 1) * step
                let (centroid, _) = windowRadius(path, tightStart, end + 1)
                loops.append(PathLoop(arcStart: arcStart, arcEnd: arcEnd,
                                      centroid: centroid,
                                      arcFraction: ((arcStart + arcEnd) / 2) / total))
                // Skip past the loop and keep scanning for more.
                start = end + 1
            } else {
                start += 1
            }
        }
        return loops
    }

    /// Detects deliberate back-and-forth wiggles: sharp reversal apexes whose
    /// legs are far shorter than one key pitch — sub-lexical by construction,
    /// since adjacent keys are at least a pitch apart (swiping.md §4.10).
    /// `detectLoops` is structurally blind to these: it accumulates *signed*
    /// turning, so a quick back-and-forth cancels to ~0 (its defense against
    /// wobble). Here we key on reversal APEXES and their LEG LENGTHS instead of
    /// net turn: a reversal whose legs are far below a pitch cannot be letter
    /// travel ("did" — d→i→d, adjacent keys — reverses with ~1.0-pitch legs; a
    /// wiggle on one key reverses with ~0.2–0.5-pitch legs). A window around any
    /// reversal apex looks locally identical regardless of excursion size, so
    /// leg length, not turn shape, is what disambiguates.
    /// Returns the same `PathLoop` shape as `detectLoops` so downstream excision
    /// and event mapping are shared. `minLeg`/`maxLeg` are absolute lengths (the
    /// caller multiplies the key-pitch tunables by `keyPitch`).
    /// Degenerate paths (< 4 points or zero arc length) return `[]`.
    static func detectWiggles(in points: [CGPoint], apexTurn: CGFloat,
                              minLeg: CGFloat, maxLeg: CGFloat) -> [PathLoop] {
        guard points.count >= 4, minLeg > degenerateEpsilon else { return [] }
        let total = arcLength(points)
        guard total > degenerateEpsilon else { return [] }

        // Resample FINER than detectLoops: spacing = minLeg / 2, so any
        // qualifying leg (>= minLeg) spans several vertices. That guarantees the
        // two apexes of one wiggle never land on adjacent vertices, so the
        // 2-vertex apex test below can never fuse two distinct reversals. Cap the
        // vertex count to bound work on very long paths; past the cap `step`
        // grows above the nominal spacing, which is fine — wiggles are short and
        // local. Arc positions stay in the ORIGINAL path's arc-length frame
        // (resampling preserves total arc length; the same invariant detectLoops
        // relies on), so `excising` needs no resampled-to-original index mapping.
        let spacing = minLeg / 2
        let count = min(max(Int((total / spacing).rounded()) + 1, 8), 512)
        let path = resample(points, count: count)
        guard path.count >= 4 else { return [] }
        let step = total / CGFloat(path.count - 1)   // actual arc between vertices

        // Per-segment directions (equal, nonzero segments after resampling) and
        // the signed turn at each interior vertex. turns[i] is the turn at
        // vertex i+1, between segment i and segment i+1.
        let segmentCount = path.count - 1
        var angles = [CGFloat](repeating: 0, count: segmentCount)
        for i in 0..<segmentCount {
            angles[i] = atan2(path[i + 1].y - path[i].y, path[i + 1].x - path[i].x)
        }
        let turnCount = segmentCount - 1
        guard turnCount >= 1 else { return [] }
        var turns = [CGFloat](repeating: 0, count: turnCount)
        for i in 0..<turnCount { turns[i] = wrapAngle(angles[i + 1] - angles[i]) }

        // Apexes: a vertex whose reversal reaches `apexTurn` within at most two
        // consecutive vertex-turns (a hairpin at fine spacing can spread across
        // two). At candidate i, test |turns[i]| and |turns[i] + turns[i+1]| and
        // take the max; if the 2-vertex form is larger, place the apex at the
        // midpoint of vertices i+1 and i+2 and consume BOTH turns, so one
        // hairpin yields exactly one apex. After each apex, resume past the
        // consumed turns (no double counting).
        var apexArcs: [CGFloat] = []
        var i = 0
        while i < turnCount {
            let single = abs(turns[i])
            let pair = (i + 1 < turnCount) ? abs(turns[i] + turns[i + 1]) : 0
            if max(single, pair) >= apexTurn {
                if pair > single {
                    apexArcs.append((CGFloat(i) + 1.5) * step)
                    i += 2
                } else {
                    apexArcs.append(CGFloat(i + 1) * step)
                    i += 1
                }
            } else {
                i += 1
            }
        }
        guard !apexArcs.isEmpty else { return [] }

        // Group consecutive apexes joined by interior legs <= maxLeg. A group
        // emits a wiggle only if it has at least ONE qualifying leg in
        // [minLeg, maxLeg]: an interior apex→apex leg, or — for the group that
        // touches a path end — the start→first-apex (leading double, "oops") or
        // last-apex→end (trailing double, "too") leg. A lone reversal whose legs
        // are all > maxLeg is ordinary lexical travel ("did") and yields
        // nothing; legs < minLeg are jitter and never qualify. Groups are split
        // by interior legs > maxLeg, so two wiggles ("committee") give two
        // PathLoops, non-overlapping by construction.
        func qualifies(_ leg: CGFloat) -> Bool { leg >= minLeg && leg <= maxLeg }

        var result: [PathLoop] = []
        let n = apexArcs.count
        var g = 0
        while g < n {
            var h = g
            while h + 1 < n && (apexArcs[h + 1] - apexArcs[h]) <= maxLeg { h += 1 }

            let leadingQualifies = g == 0 && qualifies(apexArcs[g])
            let trailingQualifies = h == n - 1 && qualifies(total - apexArcs[h])
            var hasQualifying = leadingQualifies || trailingQualifies
            var j = g
            while !hasQualifying && j < h {
                if qualifies(apexArcs[j + 1] - apexArcs[j]) { hasQualifying = true }
                j += 1
            }

            if hasQualifying {
                // arcStart/arcEnd carry a ±step margin so `excising` (which drops
                // only vertices STRICTLY inside a span) keeps the bracketing
                // vertices that stitch the de-looped path back together. The span
                // runs to the last apex, or to the path end when the trailing leg
                // qualified (the whole final excursion is the double).
                let firstApexArc = apexArcs[g]
                let lastEnd = trailingQualifies ? total : apexArcs[h]
                let arcStart = max(firstApexArc - step, 0)
                let arcEnd = min(lastEnd + step, total)

                var sumX: CGFloat = 0, sumY: CGFloat = 0, cnt: CGFloat = 0
                for v in 0..<path.count {
                    let arc = CGFloat(v) * step
                    if arc >= arcStart && arc <= arcEnd {
                        sumX += path[v].x
                        sumY += path[v].y
                        cnt += 1
                    }
                }
                let centroid: CGPoint = cnt > 0
                    ? CGPoint(x: sumX / cnt, y: sumY / cnt)
                    : path[min(max(Int((firstApexArc / step).rounded()), 0), path.count - 1)]

                result.append(PathLoop(arcStart: arcStart, arcEnd: arcEnd,
                                       centroid: centroid,
                                       arcFraction: ((arcStart + arcEnd) / 2) / total))
            }
            g = h + 1
        }
        return result
    }

    /// Returns the polyline with the given arc-length spans removed, joining the
    /// vertices that bracket each span (they are near each other for a loop) and
    /// preserving every other vertex exactly (swiping.md §4.10). If removal would
    /// leave fewer than two points (e.g. the whole path is one big loop), the
    /// original polyline is returned unchanged.
    static func excising(_ points: [CGPoint], arcRanges: [(start: CGFloat, end: CGFloat)]) -> [CGPoint] {
        guard !arcRanges.isEmpty, points.count >= 2 else { return points }
        let ranges = arcRanges.map { (min($0.start, $0.end), max($0.start, $0.end)) }

        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        var cumulative: CGFloat = 0
        for i in 0..<points.count {
            if i > 0 { cumulative += distance(points[i - 1], points[i]) }
            let inRemovedSpan = ranges.contains { cumulative > $0.0 && cumulative < $0.1 }
            if !inRemovedSpan { result.append(points[i]) }
        }
        return result.count >= 2 ? result : points
    }

    /// Wraps an angle difference into (-π, π] so signed turning accumulates
    /// without discontinuities across the ±π branch cut.
    private static func wrapAngle(_ angle: CGFloat) -> CGFloat {
        var wrapped = angle
        while wrapped <= -CGFloat.pi { wrapped += 2 * CGFloat.pi }
        while wrapped > CGFloat.pi { wrapped -= 2 * CGFloat.pi }
        return wrapped
    }

    /// Centroid of `points[lo...hi]` and the maximum distance from any of those
    /// points to that centroid (the window's enclosing radius).
    private static func windowRadius(_ points: [CGPoint], _ lo: Int, _ hi: Int) -> (centroid: CGPoint, maxDistance: CGFloat) {
        var sumX: CGFloat = 0, sumY: CGFloat = 0
        let n = CGFloat(hi - lo + 1)
        for k in lo...hi {
            sumX += points[k].x
            sumY += points[k].y
        }
        let centroid = CGPoint(x: sumX / n, y: sumY / n)
        var maxDistance: CGFloat = 0
        for k in lo...hi {
            let d = distance(points[k], centroid)
            if d > maxDistance { maxDistance = d }
        }
        return (centroid, maxDistance)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
