//
//  FieldGeometryTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Conspire

/// A wobbly closed blob, like a hand-drawn stroke.
private func blob(
    centre: CGPoint,
    radius: CGFloat,
    wobble: CGFloat = 0.1,
    samples: Int = 70,
    phase: CGFloat = 0
) -> FieldRing {
    (0..<samples).map { i in
        let a = phase + CGFloat(i) / CGFloat(samples) * .pi * 2
        let r = radius * (1 + wobble * sin(a * 3 + 1) + wobble * 0.5 * sin(a * 7))
        return CGPoint(x: centre.x + cos(a) * r, y: centre.y + sin(a) * r * 0.8)
    }
}

struct FieldGeometryTests {

    // MARK: - Conditioning

    @Test func resampleProducesRoughlyUniformSpacing() {
        let ring = FieldGeometry.resampleClosed(
            blob(centre: .zero, radius: 200), spacing: FieldGeometry.ringSpacing
        )
        #expect(ring.count > 10)
        for i in ring.indices {
            let d = FieldGeometry.distance(ring[i], ring[(i + 1) % ring.count])
            #expect(d > FieldGeometry.ringSpacing * 0.5)
            #expect(d < FieldGeometry.ringSpacing * 1.6)
        }
    }

    @Test func smoothingShrinksPerimeterButKeepsArea() {
        let ring = FieldGeometry.normalize(blob(centre: .zero, radius: 200, wobble: 0.22), passes: 0)
        let smoothed = FieldGeometry.smooth(ring, passes: 4)
        #expect(FieldGeometry.closedLength(smoothed) < FieldGeometry.closedLength(ring))
        // Smoothing tidies the edge; it should not eat the shape.
        let before = abs(FieldGeometry.area(ring))
        let after = abs(FieldGeometry.area(smoothed))
        #expect(after > before * 0.85)
    }

    @Test func containsAgreesWithObviousPoints() {
        let ring = FieldGeometry.normalize(blob(centre: .zero, radius: 200, wobble: 0))
        #expect(FieldGeometry.contains(ring, .zero))
        #expect(!FieldGeometry.contains(ring, CGPoint(x: 1000, y: 0)))
    }

    @Test func nearestLandsOnTheOutline() {
        let ring = FieldGeometry.normalize(blob(centre: .zero, radius: 200, wobble: 0))
        let near = FieldGeometry.nearest(on: ring, to: CGPoint(x: 1000, y: 0))
        #expect(near != nil)
        // Right of a 200-radius blob, the nearest outline point is ~800 away.
        #expect(abs(near!.distance - 800) < 40)
    }

    // MARK: - Combining

    @Test func unionOfOverlappingBlobsIsOneLoopLargerThanEither() {
        let a = FieldGeometry.normalize(blob(centre: CGPoint(x: 0, y: 0), radius: 200))
        let b = FieldGeometry.normalize(blob(centre: CGPoint(x: 180, y: 60), radius: 170))

        let merged = FieldGeometry.combine(a, b, mode: .union, soft: 18)
        #expect(merged != nil)
        guard let merged else { return }

        let areaA = abs(FieldGeometry.area(a))
        let areaB = abs(FieldGeometry.area(b))
        let areaMerged = abs(FieldGeometry.area(merged))
        #expect(areaMerged > areaA)
        #expect(areaMerged > areaB)
        // The union cannot exceed the two areas put together (plus a little fillet).
        #expect(areaMerged < (areaA + areaB) * 1.1)
        #expect(!FieldGeometry.selfIntersects(merged))
    }

    @Test func unionSwallowsAContainedBlob() {
        let big = FieldGeometry.normalize(blob(centre: .zero, radius: 260, wobble: 0))
        let small = FieldGeometry.normalize(blob(centre: .zero, radius: 60, wobble: 0))

        let merged = FieldGeometry.combine(big, small, mode: .union, soft: 12)
        #expect(merged != nil)
        guard let merged else { return }
        // No hole punched in the middle: the result is still one outline around everything.
        #expect(FieldGeometry.contains(merged, .zero))
        let ratio = abs(FieldGeometry.area(merged)) / abs(FieldGeometry.area(big))
        #expect(ratio > 0.92 && ratio < 1.08)
    }

    @Test func unionKeepsOnlyTheLargestLoop() {
        // Two blobs that do not touch: the result is a single outline, not both.
        let a = FieldGeometry.normalize(blob(centre: .zero, radius: 200, wobble: 0))
        let b = FieldGeometry.normalize(blob(centre: CGPoint(x: 1400, y: 0), radius: 80, wobble: 0))

        let merged = FieldGeometry.combine(a, b, mode: .union, soft: 10)
        #expect(merged != nil)
        guard let merged else { return }
        #expect(FieldGeometry.contains(merged, .zero))
        #expect(!FieldGeometry.contains(merged, CGPoint(x: 1400, y: 0)))
    }

    @Test func subtractRemovesArea() {
        let a = FieldGeometry.normalize(blob(centre: .zero, radius: 220, wobble: 0))
        let bite = FieldGeometry.normalize(blob(centre: CGPoint(x: 200, y: 0), radius: 90, wobble: 0))

        let carved = FieldGeometry.combine(a, bite, mode: .subtract, soft: 18)
        #expect(carved != nil)
        guard let carved else { return }

        #expect(abs(FieldGeometry.area(carved)) < abs(FieldGeometry.area(a)))
        // The bite is taken out of the right-hand edge, not the centre.
        #expect(FieldGeometry.contains(carved, .zero))
        #expect(!FieldGeometry.contains(carved, CGPoint(x: 205, y: 0)))
    }

    @Test func subtractingEverythingLeavesNothing() {
        let a = FieldGeometry.normalize(blob(centre: .zero, radius: 120, wobble: 0))
        let eraser = FieldGeometry.normalize(blob(centre: .zero, radius: 400, wobble: 0))
        #expect(FieldGeometry.combine(a, eraser, mode: .subtract, soft: 10) == nil)
    }

    @Test func combineReturnsAConditionedRing() {
        let a = FieldGeometry.normalize(blob(centre: .zero, radius: 200))
        let b = FieldGeometry.normalize(blob(centre: CGPoint(x: 150, y: 0), radius: 150))
        let merged = FieldGeometry.combine(a, b, mode: .union, soft: 18)
        #expect(merged != nil)
        guard let merged else { return }
        for i in merged.indices {
            let d = FieldGeometry.distance(merged[i], merged[(i + 1) % merged.count])
            #expect(d < FieldGeometry.ringSpacing * 1.8)
        }
    }

    // MARK: - Repair

    @Test func repairResolvesAFigureEight() {
        // A ring dragged through itself: cross two lobes over each other.
        var crossed: FieldRing = []
        for i in 0..<80 {
            let t = CGFloat(i) / 80 * .pi * 2
            crossed.append(CGPoint(x: cos(t) * 200, y: sin(2 * t) * 140))
        }
        #expect(FieldGeometry.selfIntersects(crossed))

        let repaired = FieldGeometry.repairIfNeeded(crossed)
        #expect(!FieldGeometry.selfIntersects(repaired))
        #expect(abs(FieldGeometry.area(repaired)) > FieldGeometry.minArea)
    }

    @Test func repairLeavesACleanRingAlone() {
        let clean = FieldGeometry.normalize(blob(centre: .zero, radius: 200))
        let repaired = FieldGeometry.repairIfNeeded(clean)
        #expect(repaired == clean)
    }

    // MARK: - Sculpting

    @Test func arcInfluencePeaksAtTheGrabAndFallsToZero() {
        let ring = FieldGeometry.normalize(blob(centre: .zero, radius: 240, wobble: 0))
        let grabPoint = CGPoint(x: 240, y: 0)
        let near = FieldGeometry.nearest(on: ring, to: grabPoint)
        #expect(near != nil)
        guard let near else { return }

        let influence = FieldGeometry.arcInfluence(ring: ring, near: near, radius: 150)
        #expect(!influence.indices.isEmpty)
        // Not everything moves: a 150 radius is well under the full perimeter.
        #expect(influence.indices.count < ring.count)

        let peak = influence.weights[near.index]
        #expect(peak > 0.9)
        for w in influence.weights {
            #expect(w >= 0 && w <= 1)
            #expect(w <= peak + 0.001)
        }
    }

    @Test func arcInfluenceUsesArcLengthNotStraightLine() {
        // A long thin shape: the far side is close in straight-line terms but
        // far around the outline, so grabbing one end must not drag the other.
        var thin: FieldRing = []
        for x in stride(from: CGFloat(-400), through: 400, by: 20) {
            thin.append(CGPoint(x: x, y: -20))
        }
        for x in stride(from: CGFloat(400), through: -400, by: -20) {
            thin.append(CGPoint(x: x, y: 20))
        }
        let ring = FieldGeometry.normalize(thin)

        let near = FieldGeometry.nearest(on: ring, to: CGPoint(x: 0, y: -20))
        #expect(near != nil)
        guard let near else { return }

        let influence = FieldGeometry.arcInfluence(ring: ring, near: near, radius: 120)
        // The opposite wall is 40pt away but ~800pt around the ring: it stays put.
        for i in ring.indices where ring[i].y > 0 {
            #expect(influence.weights[i] == 0)
        }
    }

    @Test func handleIndicesAreSpacedAndInRange() {
        let ring = FieldGeometry.normalize(blob(centre: .zero, radius: 240))
        let handles = FieldGeometry.handleIndices(ring)
        #expect(handles.count >= 8)
        #expect(handles.allSatisfy { $0 >= 0 && $0 < ring.count })
        #expect(handles == handles.sorted())
    }

    // MARK: - Persistence round trip

    @Test func ringSurvivesEncodeDecode() {
        let ring = FieldGeometry.normalize(blob(centre: CGPoint(x: 120, y: -80), radius: 200))
        let decoded = FieldEntity.decodeRing(FieldEntity.encodeRing(ring))
        #expect(decoded.count == ring.count)
        for (a, b) in zip(ring, decoded) {
            #expect(abs(a.x - b.x) < 0.0001)
            #expect(abs(a.y - b.y) < 0.0001)
        }
    }
}
