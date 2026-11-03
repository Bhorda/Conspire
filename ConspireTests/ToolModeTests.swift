//
//  ToolModeTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Conspire

/// A closed ring comfortably larger than `FieldGeometry.minArea`, so
/// `endFieldStroke` treats it as a real stroke.
private func strokeRing(radius: CGFloat = 40) -> FieldRing {
    (0..<48).map { i in
        let a = CGFloat(i) / 48 * .pi * 2
        return CGPoint(x: 200 + cos(a) * radius, y: 200 + sin(a) * radius)
    }
}

@MainActor
struct ToolModeTests {

    // MARK: - The resting state

    @Test func handIsTheDefault() {
        #expect(WhiteboardStore().placementMode == .hand)
    }

    @Test func onlyNoteAndFieldAreOneShot() {
        #expect(PlacementMode.note.returnsToHandAfterUse)
        #expect(PlacementMode.field.returnsToHandAfterUse)
        #expect(!PlacementMode.string.returnsToHandAfterUse)
        #expect(!PlacementMode.hand.returnsToHandAfterUse)
    }

    // MARK: - Picking a colour is how you pick up a tool

    @Test func colourChoiceSelectsItsTool() {
        let store = WhiteboardStore()

        store.pickNoteColour(1)
        #expect(store.placementMode == .note)
        #expect(store.noteColourPicked == 1)

        store.pickStringColour(2)
        #expect(store.placementMode == .string)

        store.pickFieldColour(0)
        #expect(store.placementMode == .field)
    }

    /// With a field selected, the field swatches mean "recolour this one" — so
    /// they must not also hand you the pencil.
    @Test func fieldColourRecoloursTheSelectionWithoutTakingThePencil() {
        let store = WhiteboardStore()
        let field = Field(ring: strokeRing(), colourIndex: 0, label: "A")
        store.fields = [field]
        store.selectField(field.id)

        store.pickFieldColour(2)

        #expect(store.fields[0].colourIndex == 2)
        #expect(store.placementMode == .hand)
    }

    // MARK: - Tools hand themselves back

    @Test func finishingReturnsTheOneShotToolsOnly() {
        let store = WhiteboardStore()

        store.placementMode = .note
        store.finishOneShotTool()
        #expect(store.placementMode == .hand)

        store.placementMode = .field
        store.finishOneShotTool()
        #expect(store.placementMode == .hand)

        store.placementMode = .string
        store.finishOneShotTool()
        #expect(store.placementMode == .string)
    }

    @Test func drawingAFieldPutsThePencilDown() {
        let store = WhiteboardStore()
        store.placementMode = .field
        store.fieldDraftStroke = strokeRing()

        store.endFieldStroke()

        #expect(store.fields.count == 1)
        #expect(store.placementMode == .hand)
        // The new field stays selected, so its panel is still there to adjust.
        #expect(store.selectedFieldID == store.fields[0].id)
    }

    /// A stroke too small to become a field is a slip, not a finished action —
    /// losing the pencil over it would be infuriating.
    @Test func aStrokeTooSmallToLandKeepsThePencil() {
        let store = WhiteboardStore()
        store.placementMode = .field
        store.fieldDraftStroke = strokeRing(radius: 3)

        store.endFieldStroke()

        #expect(store.fields.isEmpty)
        #expect(store.placementMode == .field)
    }

    // MARK: - The hand creates nothing

    @Test func canvasClickInTheHandMakesNoNote() {
        let store = WhiteboardStore()
        store.handleBackgroundPrimaryTap(atRootPoint: CGPoint(x: 120, y: 90), modifiers: InputModifiers(shift: false, command: false, option: false))

        #expect(store.editingNoteID == nil)
        #expect(store.placementMode == .hand)
    }

    @Test func canvasClickInTheHandStillDeselects() {
        let store = WhiteboardStore()
        let field = Field(ring: strokeRing(), colourIndex: 0, label: "A")
        store.fields = [field]
        store.selectField(field.id)

        store.handleBackgroundPrimaryTap(atRootPoint: CGPoint(x: 1200, y: 1200), modifiers: InputModifiers(shift: false, command: false, option: false))

        #expect(store.selectedFieldID == nil)
    }

    @Test func stackClickInTheHandAddsNoNote() {
        let store = WhiteboardStore()
        store.createNoteOnTopOfBoardStack(groupID: UUID())
        #expect(store.editingNoteID == nil)
    }

    // MARK: - Escape

    @Test func escapeDismissesEditingBeforeAnythingElse() {
        let store = WhiteboardStore()
        store.placementMode = .field
        store.editingNoteID = UUID()
        store.selectedFieldID = UUID()

        #expect(store.handleEscape())
        #expect(store.editingNoteID == nil)
        // Still selected, still the pencil: one press, one layer.
        #expect(store.selectedFieldID != nil)
        #expect(store.placementMode == .field)
    }

    @Test func escapeAbandonsAnInProgressStroke() {
        let store = WhiteboardStore()
        store.placementMode = .field
        store.fieldDraftStroke = strokeRing()

        #expect(store.handleEscape())
        #expect(store.fieldDraftStroke.isEmpty)
        #expect(store.placementMode == .field)
    }

    @Test func escapeAbandonsAnInProgressString() {
        let store = WhiteboardStore()
        store.placementMode = .string
        store.linkDraftSource = .note(UUID())

        #expect(store.handleEscape())
        #expect(store.linkDraftSource == nil)
        #expect(store.placementMode == .string)
    }

    @Test func escapeClearsSelectionBeforeTheTool() {
        let store = WhiteboardStore()
        store.placementMode = .field
        store.selectedFieldID = UUID()

        #expect(store.handleEscape())
        #expect(store.selectedFieldID == nil)
        #expect(store.placementMode == .field)

        #expect(store.handleEscape())
        #expect(store.placementMode == .hand)
    }

    /// Nothing left to dismiss: the key must fall through, or a focused text
    /// field elsewhere in the window never sees it.
    @Test func escapeInTheRestingStateIsNotHandled() {
        #expect(!WhiteboardStore().handleEscape())
    }

    @Test func escapeFromEveryToolEndsInTheHand() {
        for tool in [PlacementMode.note, .string, .field] {
            let store = WhiteboardStore()
            store.placementMode = tool
            #expect(store.handleEscape())
            #expect(store.placementMode == .hand)
        }
    }
}
