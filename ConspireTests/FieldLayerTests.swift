//
//  FieldLayerTests.swift
//  ConspireTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Conspire

private func blob(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> FieldRing {
    FieldGeometry.normalize((0..<70).map { i in
        let a = CGFloat(i) / 70 * .pi * 2
        return CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r * 0.8)
    }, passes: 1)
}

struct FieldLayerTests {

    // MARK: - World → layer mapping
    //
    // World space is y-down from the top left; Core Animation is y-up from the
    // bottom left. Getting this wrong mirrors every field vertically, which is
    // not something a unit test would otherwise notice.

    @Test func transformPlacesWorldOriginAtTopLeft() {
        let t = FieldLayerHostView.canvasTransform(pan: .zero, scale: 1, viewHeight: 1000)
        let origin = CGPoint.zero.applying(t)
        #expect(abs(origin.x - 0) < 0.0001)
        #expect(abs(origin.y - 1000) < 0.0001)
    }

    @Test func transformSendsDownwardWorldToDownwardScreen() {
        let t = FieldLayerHostView.canvasTransform(pan: .zero, scale: 1, viewHeight: 1000)
        let near = CGPoint(x: 0, y: 100).applying(t)
        let far = CGPoint(x: 0, y: 300).applying(t)
        // Further down in world space must be lower on screen, i.e. smaller y in CA.
        #expect(near.y > far.y)
        #expect(abs(near.y - 900) < 0.0001)
        #expect(abs(far.y - 700) < 0.0001)
    }

    @Test func transformAppliesPanAndScale() {
        let t = FieldLayerHostView.canvasTransform(
            pan: CGSize(width: 50, height: 30), scale: 2, viewHeight: 1000
        )
        let p = CGPoint(x: 10, y: 20).applying(t)
        // Screen, top-down: (10*2 + 50, 20*2 + 30) = (70, 70) → CA y = 1000 - 70.
        #expect(abs(p.x - 70) < 0.0001)
        #expect(abs(p.y - 930) < 0.0001)
    }

    @MainActor
    @Test func transformMatchesTheHitTestingMapping() {
        // The layer transform and the store's root→world mapping must agree, or
        // the outline you grab will not be the outline you see.
        let store = WhiteboardStore()
        store.canvasPan = CGSize(width: 120, height: -40)
        store.canvasScale = 1.75
        let height: CGFloat = 800

        let world = CGPoint(x: 260, y: 140)
        let t = FieldLayerHostView.canvasTransform(
            pan: store.pixelSnappedPan, scale: store.canvasScale, viewHeight: height
        )
        let layerPoint = world.applying(t)
        let rootPoint = CGPoint(x: layerPoint.x, y: height - layerPoint.y)

        let roundTripped = store.rootToWorld(rootPoint)
        #expect(abs(roundTripped.x - world.x) < 0.01)
        #expect(abs(roundTripped.y - world.y) < 0.01)
    }

    // MARK: - Layer reconciliation

    @MainActor
    @Test func layersAreAddedReusedAndRemoved() {
        let view = FieldLayerHostView()
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let a = Field(ring: blob(0, 0, 200), colourIndex: 0, label: "A")
        let b = Field(ring: blob(400, 100, 180), colourIndex: 1, label: "B")

        view.apply(fields: [a, b], pan: .zero, scale: 1)
        #expect(view.shapeLayerCount == 2)

        // Same fields again: layers are reused, not rebuilt.
        let before = view.shapeLayerIdentity
        view.apply(fields: [a, b], pan: CGSize(width: 40, height: 10), scale: 1.5)
        #expect(view.shapeLayerCount == 2)
        #expect(view.shapeLayerIdentity == before)

        view.apply(fields: [a], pan: .zero, scale: 1)
        #expect(view.shapeLayerCount == 1)

        view.apply(fields: [], pan: .zero, scale: 1)
        #expect(view.shapeLayerCount == 0)
    }

    @MainActor
    @Test func pathIsOnlyRebuiltWhenTheRingMoves() {
        let view = FieldLayerHostView()
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        var field = Field(ring: blob(0, 0, 200), colourIndex: 0, label: "A")
        view.apply(fields: [field], pan: .zero, scale: 1)
        let firstPath = view.firstShapePath

        // Panning and zooming must not touch the path at all — that is the whole
        // point of moving to layers.
        view.apply(fields: [field], pan: CGSize(width: 300, height: 120), scale: 2.5)
        #expect(view.firstShapePath === firstPath)

        // Reshaping must.
        field.ring = blob(0, 0, 260)
        view.apply(fields: [field], pan: .zero, scale: 1)
        #expect(view.firstShapePath !== firstPath)
    }

    @MainActor
    @Test func movingAFieldTranslatesTheLayerRatherThanRebuildingIt() {
        let view = FieldLayerHostView()
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        var field = Field(ring: blob(0, 0, 200), colourIndex: 0, label: "A")
        view.apply(fields: [field], pan: .zero, scale: 1)
        let original = view.firstShapePath

        // Dragging the field rewrites every point, but the shape is unchanged.
        field.ring = field.ring.map { CGPoint(x: $0.x + 120, y: $0.y + 40) }
        view.apply(fields: [field], pan: .zero, scale: 1)

        #expect(view.firstShapePath === original)
        #expect(abs(view.firstShapeTranslation.width - 120) < 0.001)
        #expect(abs(view.firstShapeTranslation.height - 40) < 0.001)
    }

    @Test func pureTranslationRejectsAnActualReshape() {
        let base = blob(0, 0, 200)
        var reshaped = base.map { CGPoint(x: $0.x + 10, y: $0.y + 10) }
        reshaped[3].x += 25   // one point pushed out: no longer a bodily move
        #expect(FieldLayerHostView.pureTranslation(from: base, to: reshaped) == nil)

        let moved = base.map { CGPoint(x: $0.x - 7, y: $0.y + 3) }
        let delta = FieldLayerHostView.pureTranslation(from: base, to: moved)
        #expect(delta?.width == -7)
        #expect(delta?.height == 3)
    }
}
