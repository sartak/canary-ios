//
//  PathGeometryTests.swift
//  CanaryTests
//
//  Created by Claude on 7/4/26.
//

import CoreGraphics
import Testing

private func approx(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

private func approx(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1e-6) -> Bool {
    approx(a.x, b.x, tolerance: tolerance) && approx(a.y, b.y, tolerance: tolerance)
}

private func approx(_ a: [CGPoint], _ b: [CGPoint], tolerance: CGFloat = 1e-6) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { approx($0, $1, tolerance: tolerance) }
}

struct ArcLengthTests {
    @Test func emptyAndSinglePointHaveZeroLength() {
        #expect(PathGeometry.arcLength([]) == 0)
        #expect(PathGeometry.arcLength([CGPoint(x: 5, y: 5)]) == 0)
    }

    @Test func straightSegmentIsEuclideanDistance() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4)]
        #expect(approx(PathGeometry.arcLength(path), 5))
    }

    @Test func polylineSumsSegments() {
        let lShape = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        #expect(approx(PathGeometry.arcLength(lShape), 20))
    }
}

struct ResampleTests {
    @Test func lShapeResamplesToEquidistantPoints() {
        let lShape = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let resampled = PathGeometry.resample(lShape, count: 5)
        let expected = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 5, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 5),
            CGPoint(x: 10, y: 10),
        ]
        #expect(approx(resampled, expected))
    }

    @Test func preservesEndpoints() {
        let path = [CGPoint(x: 1, y: 2), CGPoint(x: 7, y: 3), CGPoint(x: 4, y: 9)]
        let resampled = PathGeometry.resample(path, count: 64)
        #expect(resampled.count == 64)
        #expect(approx(resampled.first!, path.first!, tolerance: 1e-3))
        #expect(approx(resampled.last!, path.last!, tolerance: 1e-3))
    }

    @Test func consecutivePointsAreEquidistant() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 8), CGPoint(x: 9, y: 1), CGPoint(x: 12, y: 12)]
        let resampled = PathGeometry.resample(path, count: 32)
        let expectedSpacing = PathGeometry.arcLength(path) / 31
        for i in 1..<resampled.count {
            let dx = resampled[i].x - resampled[i - 1].x
            let dy = resampled[i].y - resampled[i - 1].y
            // Resampling measures along the original polyline; straight-line spacing
            // between consecutive samples can only be <= the arc spacing.
            #expect((dx * dx + dy * dy).squareRoot() <= expectedSpacing + 1e-3)
        }
    }

    @Test func singlePointRepeats() {
        let resampled = PathGeometry.resample([CGPoint(x: 3, y: 3)], count: 4)
        #expect(approx(resampled, Array(repeating: CGPoint(x: 3, y: 3), count: 4)))
    }

    @Test func zeroLengthPathRepeats() {
        let path = [CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 3)]
        let resampled = PathGeometry.resample(path, count: 3)
        #expect(approx(resampled, Array(repeating: CGPoint(x: 3, y: 3), count: 3)))
    }

    @Test func duplicateInteriorPointsAreHandled() {
        // Touch events can report the same point twice; must not stall or skew.
        let path = [
            CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0),
        ]
        let resampled = PathGeometry.resample(path, count: 3)
        let expected = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0)]
        #expect(approx(resampled, expected))
    }

    @Test func emptyInputGivesEmptyOutput() {
        #expect(PathGeometry.resample([], count: 8).isEmpty)
    }
}

struct TruncatedTests {
    @Test func truncatesMidSegment() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        let truncated = PathGeometry.truncated(path, atArcLength: 4)
        #expect(approx(truncated, [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)]))
    }

    @Test func truncatesAtSegmentBoundary() {
        let lShape = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let truncated = PathGeometry.truncated(lShape, atArcLength: 10)
        #expect(approx(truncated, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]))
    }

    @Test func truncatesAcrossCorner() {
        let lShape = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let truncated = PathGeometry.truncated(lShape, atArcLength: 13)
        #expect(approx(truncated, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 3)]))
    }

    @Test func lengthBeyondPathReturnsWholePath() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        #expect(approx(PathGeometry.truncated(path, atArcLength: 99), path))
    }

    @Test func zeroLengthReturnsStartPoint() {
        let path = [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 0)]
        #expect(approx(PathGeometry.truncated(path, atArcLength: 0), [CGPoint(x: 2, y: 2)]))
    }
}

struct NormalizedTests {
    @Test func centroidMovesToOrigin() {
        let path = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 15, y: 25)]
        let normalized = PathGeometry.normalized(path, toSize: 1)
        let cx = normalized.reduce(0) { $0 + $1.x } / CGFloat(normalized.count)
        let cy = normalized.reduce(0) { $0 + $1.y } / CGFloat(normalized.count)
        #expect(approx(cx, 0))
        #expect(approx(cy, 0))
    }

    @Test func longSideScalesToSizePreservingAspect() {
        // 20 wide x 10 tall
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 10)]
        let normalized = PathGeometry.normalized(path, toSize: 1)
        let xs = normalized.map(\.x)
        let ys = normalized.map(\.y)
        #expect(approx(xs.max()! - xs.min()!, 1.0))
        #expect(approx(ys.max()! - ys.min()!, 0.5))
    }

    @Test func degeneratePointCloudTranslatesOnly() {
        let path = [CGPoint(x: 7, y: 7), CGPoint(x: 7, y: 7)]
        let normalized = PathGeometry.normalized(path, toSize: 1)
        #expect(approx(normalized, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)]))
    }

    @Test func flatHorizontalLineScalesByWidth() {
        let path = [CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5)]
        let normalized = PathGeometry.normalized(path, toSize: 1)
        #expect(approx(normalized, [CGPoint(x: -0.5, y: 0), CGPoint(x: 0.5, y: 0)]))
    }
}

struct PointwiseDistanceTests {
    @Test func identicalPathsHaveZeroDistance() {
        let path = [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]
        #expect(approx(PathGeometry.meanPointwiseDistance(path, path), 0))
    }

    @Test func uniformOffsetGivesThatOffset() {
        let a = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        let b = [CGPoint(x: 0, y: 2), CGPoint(x: 10, y: 2)]
        #expect(approx(PathGeometry.meanPointwiseDistance(a, b), 2))
    }

    @Test func weightedDistanceUsesWeights() {
        let a = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        let b = [CGPoint(x: 0, y: 4), CGPoint(x: 10, y: 8)]
        // 0.75 * 4 + 0.25 * 8 = 5
        let distance = PathGeometry.weightedPointwiseDistance(a, b, weights: [0.75, 0.25])
        #expect(approx(distance, 5))
    }
}
