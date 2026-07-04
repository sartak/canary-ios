//
//  PathGeometry.swift
//  Keyboard
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics

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

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
