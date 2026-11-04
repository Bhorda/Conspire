//
//  InteractionConsistencyTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Conspire

// MARK: - Selection is exclusive

/// Four kinds of object each had their own selected-id, and each `select…`
/// cleared a different subset of the others. These are the combinations that
/// were actually wrong, written as the rule rather than as the bugs: whatever
/// you select, nothing else stays selected.
@MainActor
struct SelectionExclusivityTests {

    /// Every pair, both ways round, rather than the handful that were broken —
    /// the funnel is only worth having if it holds for all of them.
    @Test func onlyOneThingIsEverSelected() throws {
        let temp = try TemporaryStore()
        let store = temp.store
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        let asset = temp.placeImage(at: CGPoint(x: 500, y: 500))!
        store.placementMode = .field
        store.fieldDraftStroke = (0..<48).map { i in
            let a = CGFloat(i) / 48 * .pi * 2
            return CGPoint(x: 900 + cos(a) * 60, y: 900 + sin(a) * 60)
        }
        store.endFieldStroke()
        let fieldID = try #require(store.fields.first?.id)
        let link = Link(from: .note(noteID), to: .note(UUID()), colorIndex: 0)
        store.links[link.id] = link

        let selectors: [(name: String, apply: () -> Void, held: () -> Bool)] = [
            ("note", { store.selectNote(noteID) }, { store.selectedNoteID != nil }),
            ("image", { store.selectImage(asset.id) }, { store.selectedImageID != nil }),
            ("field", { store.selectField(fieldID) }, { store.selectedFieldID != nil }),
            ("link", { store.selectLink(link.id) }, { store.selectedLinkID != nil }),
        ]

        for first in selectors {
            for second in selectors where second.name != first.name {
                first.apply()
                second.apply()
                #expect(second.held(), "selecting the \(second.name) did not take")
                #expect(
                    !first.held(),
                    "the \(first.name) stayed selected after the \(second.name) was"
                )
            }
        }
    }

    /// The one the user saw: an image stayed outlined while they typed.
    @Test func editingANoteClearsEverythingElse() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        let asset = temp.placeImage(at: CGPoint(x: 500, y: 500))!

        temp.store.selectImage(asset.id)
        temp.store.startEditing(note: noteID)

        #expect(temp.store.editingNoteID == noteID)
        #expect(temp.store.selectedImageID == nil)
    }

    /// And the other way: picking something up off the canvas commits the words.
    @Test func selectingSomethingElseEndsEditing() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        let asset = temp.placeImage(at: CGPoint(x: 500, y: 500))!

        temp.store.startEditing(note: noteID)
        temp.store.selectImage(asset.id)

        #expect(temp.store.editingNoteID == nil)
        #expect(temp.store.selectedImageID == asset.id)
    }

    @Test func clearSelectionAlsoStopsEditing() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!

        temp.store.startEditing(note: noteID)
        temp.store.clearSelection()

        #expect(temp.store.editingNoteID == nil)
        #expect(!temp.store.hasSelection)
    }

    /// `handleBackgroundPrimaryTap` reads "was editing" to decide whether the
    /// click was a commit or a creation, and the clear now ends editing — so
    /// the read has to come first or the note tool makes a second note.
    @Test func committingWordsOnTheBackgroundDoesNotAlsoCreate() throws {
        let temp = try TemporaryStore()
        temp.store.placementMode = .note
        temp.store.handleBackgroundPrimaryTap(atRootPoint: CGPoint(x: 40, y: 40), modifiers: .none)
        let firstNote = try #require(temp.store.editingNoteID)

        temp.store.placementMode = .note
        temp.store.handleBackgroundPrimaryTap(atRootPoint: CGPoint(x: 300, y: 300), modifiers: .none)

        #expect(temp.store.editingNoteID == nil, "the click should have committed, not created")
        #expect(temp.store.activeNotesByID[firstNote] != nil)
        #expect(temp.store.activeGroups.count == 1)
    }
}

// MARK: - A click on a note acts at once

/// The inspector used to arrive a third of a second late, because a `count: 2`
/// tap gesture beside a plain one holds the single tap back until it knows no
/// second click is coming. The store counts clicks instead.
@MainActor
struct NoteClickIntentTests {
    private let noteA = UUID()
    private let noteB = UUID()

    @Test func theFirstClickSelects() {
        #expect(WhiteboardStore().noteClickIntent(for: noteA) == .select)
    }

    @Test func aSecondClickOnTheSameNoteEdits() {
        let store = WhiteboardStore()
        let t = Date()
        #expect(store.noteClickIntent(for: noteA, at: t) == .select)
        #expect(store.noteClickIntent(for: noteA, at: t.addingTimeInterval(0.1)) == .edit)
    }

    @Test func aSlowSecondClickSelectsAgain() {
        let store = WhiteboardStore()
        let t = Date()
        _ = store.noteClickIntent(for: noteA, at: t)
        #expect(store.noteClickIntent(for: noteA, at: t.addingTimeInterval(2)) == .select)
    }

    @Test func aFastClickOnADifferentNoteSelectsIt() {
        let store = WhiteboardStore()
        let t = Date()
        _ = store.noteClickIntent(for: noteA, at: t)
        #expect(store.noteClickIntent(for: noteB, at: t.addingTimeInterval(0.05)) == .select)
    }

    /// A triple-click is not two edits: the pair is consumed, so the third
    /// click starts counting again.
    @Test func theThirdClickStartsOver() {
        let store = WhiteboardStore()
        let t = Date()
        _ = store.noteClickIntent(for: noteA, at: t)
        _ = store.noteClickIntent(for: noteA, at: t.addingTimeInterval(0.05))
        #expect(store.noteClickIntent(for: noteA, at: t.addingTimeInterval(0.1)) == .select)
    }
}

// MARK: - Carrying

/// Holding notes is meant to trump every other interaction. It did not: the
/// pointer offset was measured in screen points while the cards grew with the
/// zoom, and three interaction layers claimed the click that was meant to put
/// the pile down.
@MainActor
struct CarryMechanicsTests {

    /// The property that was wrong. The gap between the pointer and the pile is
    /// now a fixed distance in world units, so on screen it grows with the
    /// cards instead of being swallowed by them.
    @Test func theCarryOffsetIsConstantInWorldUnits() {
        let cursor = CGPoint(x: 400, y: 300)
        let anchors = [0.25, 0.5, 1.0, 2.0, 4.0].map { scale in
            WhiteboardStore.carryAnchorWorld(
                cursorInRoot: cursor, pan: .zero, scale: CGFloat(scale)
            )
        }
        let cursorWorlds = [0.25, 0.5, 1.0, 2.0, 4.0].map { scale in
            CGPoint(x: cursor.x / CGFloat(scale), y: cursor.y / CGFloat(scale))
        }
        for (anchor, cursorWorld) in zip(anchors, cursorWorlds) {
            #expect(abs(anchor.x - cursorWorld.x - WhiteboardStyle.handFollowOffset.width) < 0.0001)
            #expect(
                abs(anchor.y - cursorWorld.y - WhiteboardStyle.handFollowOffset.height) < 0.0001
            )
        }
    }

    /// And the consequence, stated the way it is felt: at any zoom the pile
    /// clears the pointer by the same fraction of a card.
    @Test func thePileClearsThePointerByTheSameFractionOfACardAtAnyZoom() {
        let cursor = CGPoint(x: 400, y: 300)
        let gapsInCards: [CGFloat] = [0.3, 1.0, 3.0].map { scale in
            let anchor = WhiteboardStore.carryAnchorWorld(
                cursorInRoot: cursor, pan: .zero, scale: scale
            )
            let cursorWorld = CGPoint(x: cursor.x / scale, y: cursor.y / scale)
            // Anchor is the bottom-centre, so the card's left edge is half a
            // card to its left.
            let leftEdge = anchor.x - WhiteboardStyle.noteSize.width / 2
            return (leftEdge - cursorWorld.x) / WhiteboardStyle.noteSize.width
        }
        let first = gapsInCards[0]
        for gap in gapsInCards {
            #expect(abs(gap - first) < 0.0001)
            #expect(gap > 0, "the pile would be sitting on the pointer")
        }
    }

    /// The bug as it was felt: a click on a picture selected the picture
    /// instead of putting the notes down. Placement itself is animated, so what
    /// is asserted here is the routing — which is the thing that was wrong.
    @Test func clickingAPictureWhileCarryingDoesNotSelectIt() throws {
        let temp = try TemporaryStore()
        let store = temp.store
        let asset = temp.placeImage(at: CGPoint(x: 400, y: 400))!
        _ = try #require(stageACarry(temp))
        // Picking the notes up is itself an interaction, so it let go of the
        // picture its own placement had selected.
        #expect(store.selectedImageID == nil)

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))

        #expect(store.selectedImageID == nil, "the click selected the picture instead")
    }

    /// The string tool's own job on a picture — pin this point and connect it —
    /// still loses to a hand that is full.
    @Test func carryingBeatsEvenTheStringTool() throws {
        let temp = try TemporaryStore()
        let store = temp.store
        let asset = temp.placeImage(at: CGPoint(x: 400, y: 400))!
        _ = try #require(stageACarry(temp))
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))

        #expect(store.pins.isEmpty, "a pin was made while the hand was full")
    }

    /// What you see is where it lands. The pile floats clear of the pointer so
    /// you can aim it; placing used to ignore that and drop it on the pointer
    /// instead, sliding it half a card off the spot you had just lined up.
    @Test func thePileLandsWhereThePreviewShowedIt() throws {
        let temp = try TemporaryStore()
        let store = temp.store
        _ = try #require(stageACarry(temp))
        store.canvasScale = 2
        store.cursorInRoot = CGPoint(x: 640, y: 480)

        store.placeCarriedAtCursor(modifiers: .none)

        let expected = WhiteboardStore.carryAnchorWorld(
            cursorInRoot: store.cursorInRoot, pan: store.canvasPan, scale: store.canvasScale
        )
        let anchor = try #require(store.carriedGroup?.anchor)
        #expect(abs(anchor.x - expected.x) < 0.0001)
        #expect(abs(anchor.y - expected.y) < 0.0001)
        // And not on the pointer, which is where it used to go.
        let pointerWorld = store.rootToWorld(store.cursorInRoot)
        #expect(abs(anchor.x - pointerWorld.x) > 1)
    }

    @Test func thereIsOneAnswerToAClickWhileCarrying() throws {
        let temp = try TemporaryStore()
        #expect(!temp.store.placeCarriedAtCursor(modifiers: .none), "nothing was in hand")
        _ = try #require(stageACarry(temp))
        #expect(temp.store.placeCarriedAtCursor(modifiers: .none))
    }

    /// Escape is documented as abandoning whatever is in progress, and a pile of
    /// notes in hand is the most in-progress thing on the board. It used to step
    /// straight over the carry to the selection underneath — so the test is
    /// that the selection survives the press that the carry consumed.
    @Test func escapeTakesTheCarryBeforeTheSelection() throws {
        let temp = try TemporaryStore()
        let store = temp.store
        let asset = temp.placeImage(at: CGPoint(x: 900, y: 900))!
        _ = try #require(stageACarry(temp))
        store.selectImage(asset.id)

        #expect(store.handleEscape())
        #expect(store.selectedImageID == asset.id, "Escape skipped the carry")

        // Nothing in hand: the next press is the selection's.
        store.handleDeleteHandShortcut()
        #expect(!store.isCarrying)
        #expect(store.handleEscape())
        #expect(store.selectedImageID == nil)
    }

    @Test func escapeStillFallsThroughWithNothingToDo() throws {
        let temp = try TemporaryStore()
        #expect(!temp.store.handleEscape())
    }

    /// Puts one group in the hand. Returns the carried group's id.
    private func stageACarry(_ temp: TemporaryStore) -> UUID? {
        let noteID = temp.service.createNote(atWorldCenter: CGPoint(x: 100, y: 100), colour: 0)
        guard noteID != nil, let group = temp.store.activeGroups.first else { return nil }
        temp.store.cursorInRoot = CGPoint(x: 200, y: 200)
        temp.store.pickUp(groupID: group.id, modifiers: .none)
        return temp.store.carriedGroup?.id
    }
}

// MARK: - The camera

/// Locating something moved the notes and the pictures separately: a SwiftUI
/// animation interpolates its own layers every frame but hands an
/// `NSViewRepresentable` only the destination, and the pictures are Core
/// Animation layers behind one. The store steps the camera itself now.
@MainActor
struct CameraAnimationTests {
    private let viewport = CGSize(width: 1000, height: 600)

    @Test func focusAimsAtThePanThatCentresThePoint() {
        let store = WhiteboardStore()
        let point = CGPoint(x: 900, y: 700)

        store.focus(worldPoint: point, viewportSize: viewport)

        let expected = WhiteboardStore.panCentring(
            worldPoint: point, viewportSize: viewport, scale: store.canvasScale
        )
        let target = store.cameraTarget
        #expect(target?.pan.width == expected.width)
        #expect(target?.pan.height == expected.height)
    }

    /// The point of stepping it: the move takes time rather than landing in one
    /// state change, which is what let the two halves of the canvas separate.
    @Test func theCameraDoesNotJumpStraightToTheTarget() {
        let store = WhiteboardStore()
        store.focus(worldPoint: CGPoint(x: 900, y: 700), viewportSize: viewport)
        #expect(store.canvasPan == .zero)
    }

    /// Arrival, without the wall clock. The loop that drives this is a sleep
    /// and a counter; the shape of the move is `cameraStep`, and checking it
    /// directly keeps the test off a timer that a busy machine would decide.
    @Test func theGlideStartsWhereItIsAndEndsOnTheTarget() {
        let from = (pan: CGSize(width: 10, height: 20), scale: CGFloat(1))
        let to = (pan: CGSize(width: -400, height: -400), scale: CGFloat(2.5))

        let first = WhiteboardStore.cameraStep(from: from, to: to, progress: 0)
        #expect(first.pan == from.pan)
        #expect(first.scale == from.scale)

        let last = WhiteboardStore.cameraStep(from: from, to: to, progress: 1)
        #expect(last.pan == to.pan)
        #expect(last.scale == to.scale)
    }

    /// Pan and scale move on one curve, so a locate that zooms does not slide
    /// and scale on two different schedules.
    @Test func panAndScaleShareOneCurve() {
        let from = (pan: CGSize(width: 0, height: 0), scale: CGFloat(1))
        let to = (pan: CGSize(width: 100, height: 200), scale: CGFloat(3))

        for progress in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let step = WhiteboardStore.cameraStep(from: from, to: to, progress: progress)
            let panFraction = step.pan.width / 100
            let scaleFraction = (step.scale - 1) / 2
            #expect(abs(panFraction - scaleFraction) < 0.0001)
            #expect(abs(step.pan.height / 200 - panFraction) < 0.0001)
        }
    }

    @Test func theGlideNeverGoesBackwards() {
        let from = (pan: CGSize.zero, scale: CGFloat(1))
        let to = (pan: CGSize(width: 500, height: 0), scale: CGFloat(1))
        var previous: CGFloat = -1
        for frame in 0...21 {
            let step = WhiteboardStore.cameraStep(
                from: from, to: to, progress: CGFloat(frame) / 21
            )
            #expect(step.pan.width >= previous)
            previous = step.pan.width
        }
        #expect(abs(previous - 500) < 0.0001)
    }

    /// A hand on the trackpad beats a glide that is still running, or the two
    /// fight over the same value.
    @Test func aPanCancelsTheGlide() {
        let store = WhiteboardStore()
        store.focus(worldPoint: CGPoint(x: 900, y: 700), viewportSize: viewport)
        #expect(store.cameraTarget != nil)

        store.applyPan(CGSize(width: 10, height: 0))

        #expect(store.cameraTarget == nil)
        #expect(store.canvasPan.width == 10)
    }

    @Test func aZoomCancelsTheGlide() {
        let store = WhiteboardStore()
        store.focus(worldPoint: CGPoint(x: 900, y: 700), viewportSize: viewport)

        store.applyZoom(magnification: 0.3, atRootPoint: CGPoint(x: 500, y: 300))

        #expect(store.cameraTarget == nil)
    }

    @Test func smoothstepStartsAndEndsFlat() {
        #expect(WhiteboardStore.easeInOut(0) == 0)
        #expect(WhiteboardStore.easeInOut(1) == 1)
        #expect(abs(WhiteboardStore.easeInOut(0.5) - 0.5) < 0.0001)
        // Clamped, so a stray frame index cannot overshoot the destination.
        #expect(WhiteboardStore.easeInOut(-1) == 0)
        #expect(WhiteboardStore.easeInOut(2) == 1)
    }

}
