//
//  LibraryTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Conspire

@MainActor
struct ImageLibraryMigrationTests {

    /// A placement as it was written before the library existed: its own bytes,
    /// no resource. This is the shape sitting in the user's real store.
    private func legacyPlacement(
        in temp: TemporaryStore, boardID: UUID, width: Int = 800, height: Int = 400
    ) throws -> UUID {
        let prepared = ImageCodec.prepare(
            originalData: makeTestImageData(width: width, height: height)
        )!
        let entity = ImageEntity(
            boardID: boardID,
            resourceID: nil,
            originalData: prepared.originalData,
            displayData: prepared.displayData,
            x: 10, y: 20, width: 400, height: 200,
            zOrder: 0,
            nativeWidth: prepared.nativePixelSize.width,
            nativeHeight: prepared.nativePixelSize.height,
            displayPixelCap: prepared.displayPixelCap
        )
        temp.service.context!.insert(entity)
        try temp.service.context!.save()
        return entity.id
    }

    @Test func aLegacyPlacementGainsAResourceHoldingTheSameBytes() throws {
        let temp = try TemporaryStore()
        let boardID = temp.service.activeBoardID!
        let placementID = try legacyPlacement(in: temp, boardID: boardID)
        let originalBytes = temp.store.imageEntity(id: placementID)!.displayData

        temp.store.loadLibraryForActiveProject()
        temp.store.loadImagesForActiveBoard()

        #expect(temp.store.imageResources.count == 1)
        let resource = temp.store.imageResources[0]
        #expect(temp.store.imageEntity(id: placementID)?.resourceID == resource.id)

        let entity = temp.store.imageResourceEntity(id: resource.id)!
        #expect(entity.displayData == originalBytes)
        #expect(entity.thumbnailData.isEmpty == false)
        #expect(resource.nativePixelSize == CGSize(width: 800, height: 400))
    }

    /// The legacy blobs are deliberately left in place. Duplicated bytes for a
    /// handful of old rows beats any chance of losing them.
    @Test func migrationDoesNotClearTheOldBytes() throws {
        let temp = try TemporaryStore()
        let placementID = try legacyPlacement(in: temp, boardID: temp.service.activeBoardID!)

        temp.store.loadLibraryForActiveProject()
        temp.store.loadImagesForActiveBoard()

        #expect(temp.store.imageEntity(id: placementID)?.displayData.isEmpty == false)
        #expect(temp.store.imageEntity(id: placementID)?.originalData.isEmpty == false)
    }

    /// Loading a board runs this, so it runs constantly. A second pass must not
    /// mint a second resource for the same picture.
    @Test func migrationIsIdempotent() throws {
        let temp = try TemporaryStore()
        _ = try legacyPlacement(in: temp, boardID: temp.service.activeBoardID!)

        temp.store.loadLibraryForActiveProject()
        temp.store.loadImagesForActiveBoard()
        let first = temp.store.imageResources.map(\.id)

        temp.store.loadImagesForActiveBoard()
        temp.store.loadLibraryForActiveProject()
        temp.store.loadImagesForActiveBoard()

        #expect(temp.store.imageResources.map(\.id) == first)
        #expect(try temp.service.context!.fetch(FetchDescriptor<ImageResourceEntity>()).count == 1)
    }

    @Test func aPlacementThatAlreadyHasAResourceIsLeftAlone() throws {
        let temp = try TemporaryStore()
        let asset = temp.placeImage()!
        let resourceID = asset.resourceID

        temp.store.migrateImagePlacementsToResources()

        #expect(temp.store.imageResources.count == 1)
        #expect(temp.store.imageResources[0].id == resourceID)
    }

    @Test func theMigratedPictureStillRendersAfterAReopen() throws {
        let temp = try TemporaryStore()
        _ = try legacyPlacement(in: temp, boardID: temp.service.activeBoardID!)
        temp.store.loadLibraryForActiveProject()
        temp.store.loadImagesForActiveBoard()

        let reread = try temp.reopen()
        let resources = try reread.fetch(FetchDescriptor<ImageResourceEntity>())
        let placements = try reread.fetch(FetchDescriptor<ImageEntity>())

        #expect(resources.count == 1)
        #expect(placements.count == 1)
        #expect(placements.first?.resourceID == resources.first?.id)
        // The bytes are readable from the resource, which is what the canvas
        // now draws from.
        #expect(ImageCodec.decode(resources.first!.displayData) != nil)
    }

    @Test func migrationLosesNoPlacements() throws {
        let temp = try TemporaryStore()
        let boardID = temp.service.activeBoardID!
        _ = try legacyPlacement(in: temp, boardID: boardID)
        _ = try legacyPlacement(in: temp, boardID: boardID, width: 600, height: 600)

        temp.store.loadLibraryForActiveProject()
        temp.store.loadImagesForActiveBoard()

        #expect(temp.store.images.count == 2)
        #expect(temp.store.imageResources.count == 2)
        #expect(temp.store.images.allSatisfy { asset in
            temp.store.imageResources.contains { $0.id == asset.resourceID }
        })
    }
}

@MainActor
struct LibraryResourceTests {

    private func resource(_ temp: TemporaryStore, name: String = "Photo") -> ImageResource {
        let prepared = ImageCodec.prepare(originalData: makeTestImageData(width: 800, height: 400))!
        return temp.store.addImageResource(prepared, name: name)!
    }

    @Test func removingAPlacementLeavesThePictureInTheLibrary() throws {
        let temp = try TemporaryStore()
        let asset = temp.placeImage()!

        temp.store.deleteImage(asset.id)

        #expect(temp.store.images.isEmpty)
        // Taking a picture off a board is not throwing the photo away.
        #expect(temp.store.imageResources.count == 1)
    }

    @Test func removingThePictureTakesEveryPlacement() throws {
        let temp = try TemporaryStore()
        let shared = resource(temp)
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 100, y: 100))
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 700, y: 100))
        #expect(temp.store.images.count == 2)

        temp.store.deleteImageResource(shared.id)

        #expect(temp.store.images.isEmpty)
        #expect(temp.store.imageResources.isEmpty)
        #expect(try temp.service.context!.fetch(FetchDescriptor<ImageEntity>()).isEmpty)
    }

    @Test func placingTheSamePictureTwiceSharesItsDecode() throws {
        let temp = try TemporaryStore()
        let shared = resource(temp)
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 100, y: 100))
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 700, y: 100))

        #expect(temp.store.images.count == 2)
        #expect(Set(temp.store.images.map(\.resourceID)).count == 1)
        #expect(temp.store.imageContents.count == 1)
    }

    @Test func aResampleReachesEveryPlacement() throws {
        let temp = try TemporaryStore()
        let prepared = ImageCodec.prepare(
            originalData: makeTestImageData(width: 4000, height: 2000)
        )!
        let shared = temp.store.addImageResource(prepared, name: "Big")!
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 100, y: 100))
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 900, y: 100))
        #expect(temp.store.images.allSatisfy { $0.displayPixelCap == 1024 })

        // Blow one placement up until its pixels run out.
        temp.store.images[0].worldRect = CGRect(x: 0, y: 0, width: 1600, height: 800)
        #expect(temp.store.canResampleImage(temp.store.images[0]))
    }

    @Test func aPictureNotOnAnyBoardHasNoUses() throws {
        let temp = try TemporaryStore()
        let orphan = resource(temp)
        #expect(temp.store.imageUses(of: orphan.id).isEmpty)
    }
}

@MainActor
struct ResourceUsesTests {

    @Test func usesListOneRowPerPlacementWithItsBoard() throws {
        let temp = try TemporaryStore()
        let firstBoard = temp.service.activeBoardID!
        let prepared = ImageCodec.prepare(originalData: makeTestImageData(width: 800, height: 400))!
        let shared = temp.store.addImageResource(prepared, name: "Shared")!

        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 100, y: 100))
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 700, y: 100))

        // A second board with one more placement.
        temp.service.createBoard()
        temp.store.activeBoardID = temp.service.activeBoardID
        temp.store.images = []
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 300, y: 300))

        let uses = temp.store.imageUses(of: shared.id)
        #expect(uses.count == 3)
        #expect(Set(uses.map(\.boardID)).count == 2)
        // The two on the first board are separate rows, not one.
        #expect(uses.filter { $0.boardID == firstBoard }.count == 2)
        #expect(uses.contains { $0.isOnActiveBoard })
        #expect(uses.contains { !$0.isOnActiveBoard })
    }

    @Test func aUseKnowsWhereOnTheBoardItIs() throws {
        let temp = try TemporaryStore()
        let prepared = ImageCodec.prepare(originalData: makeTestImageData(width: 800, height: 400))!
        let shared = temp.store.addImageResource(prepared, name: "Shared")!
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 250, y: 150))

        let use = temp.store.imageUses(of: shared.id).first
        // Placed centred on the drop point, so that is where Locate aims.
        #expect(use?.worldPoint.x == 250)
        #expect(use?.worldPoint.y == 150)
    }

    // MARK: - Locate

    @Test func theCentringPanPutsAPointInTheMiddle() {
        let viewport = CGSize(width: 1200, height: 800)
        let pan = WhiteboardStore.panCentring(
            worldPoint: CGPoint(x: 500, y: 300), viewportSize: viewport, scale: 1
        )
        // Applying it should map the world point to the viewport centre.
        #expect(500 * 1 + pan.width == 600)
        #expect(300 * 1 + pan.height == 400)
    }

    @Test func theCentringPanAccountsForZoom() {
        let viewport = CGSize(width: 1200, height: 800)
        for scale in [0.25, 0.5, 1.0, 2.0, 3.5] as [CGFloat] {
            let point = CGPoint(x: 820, y: -140)
            let pan = WhiteboardStore.panCentring(
                worldPoint: point, viewportSize: viewport, scale: scale
            )
            #expect(abs(point.x * scale + pan.width - 600) < 0.0001)
            #expect(abs(point.y * scale + pan.height - 400) < 0.0001)
        }
    }

    @Test func locatingOnAnotherBoardSwitchesToIt() throws {
        let temp = try TemporaryStore()
        let prepared = ImageCodec.prepare(originalData: makeTestImageData(width: 800, height: 400))!
        let shared = temp.store.addImageResource(prepared, name: "Shared")!
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 100, y: 100))

        temp.service.createBoard()
        let secondBoard = temp.service.activeBoardID!
        temp.store.activeBoardID = secondBoard
        temp.store.images = []
        temp.store.placeImageResource(shared.id, atWorld: CGPoint(x: 400, y: 400))

        var reloaded = false
        temp.store.onBoardSwitched = { reloaded = true }

        let elsewhere = temp.store.imageUses(of: shared.id).first { !$0.isOnActiveBoard }!
        temp.store.locate(elsewhere, viewportSize: CGSize(width: 1000, height: 600))

        #expect(temp.service.activeBoardID == elsewhere.boardID)
        #expect(reloaded)
    }

    @Test func locatingOnTheOpenBoardDoesNotSwitch() throws {
        let temp = try TemporaryStore()
        let asset = temp.placeImage(at: CGPoint(x: 900, y: 700))!
        let boardID = temp.service.activeBoardID

        var reloaded = false
        temp.store.onBoardSwitched = { reloaded = true }
        let use = temp.store.imageUses(of: asset.resourceID).first!
        temp.store.locate(use, viewportSize: CGSize(width: 1000, height: 600))

        #expect(!reloaded)
        #expect(temp.service.activeBoardID == boardID)
        // And it still moved the canvas to the thing.
        #expect(abs(900 * temp.store.canvasScale + temp.store.canvasPan.width - 500) < 0.0001)
    }
}

@MainActor
struct TextLibraryTests {

    @Test func aNoteFromTheLibraryShowsTheResourcesWords() throws {
        let temp = try TemporaryStore()
        let resource = temp.store.addTextResource("Trust & safety")!
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 100, y: 100))

        let note = temp.service.activeNotesByID.values.first
        #expect(note?.text == "Trust & safety")
        #expect(note?.textResourceID == resource.id)
    }

    /// The whole point of sharing: fixing the wording once fixes it everywhere.
    @Test func editingTheResourceChangesEveryNote() throws {
        let temp = try TemporaryStore()
        let resource = temp.store.addTextResource("Trust")!
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 100, y: 100))
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 400, y: 100))

        temp.store.updateTextResource(resource.id, text: "Trust & safety")

        let texts = Set(temp.service.activeNotesByID.values.map(\.text))
        #expect(texts == ["Trust & safety"])
    }

    @Test func editingALibraryNoteOnTheBoardEditsTheResource() throws {
        let temp = try TemporaryStore()
        let resource = temp.store.addTextResource("Trust")!
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 100, y: 100))
        let noteID = temp.service.activeNotesByID.keys.first!

        temp.service.updateNoteText(noteID: noteID, text: "Trust & safety")

        #expect(temp.store.textResourceEntity(id: resource.id)?.text == "Trust & safety")
    }

    /// Typing in a note gets that note its own item, and leaves every other
    /// item alone.
    @Test func typingInANoteDoesNotDisturbOtherItems() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        let other = temp.store.addTextResource("Trust")!
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!

        temp.service.updateNoteText(noteID: noteID, text: "something else")

        #expect(temp.store.textResourceEntity(id: other.id)?.text == "Trust")
        let mine = temp.service.activeNotesByID[noteID]?.textResourceID
        #expect(mine != nil)
        #expect(mine != other.id)
    }

    /// Removing a library item must not quietly empty notes on boards the user
    /// is not looking at.
    @Test func removingAResourceLeavesItsNotesReadable() throws {
        let temp = try TemporaryStore()
        let resource = temp.store.addTextResource("Trust & safety")!
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 100, y: 100))

        temp.store.deleteTextResource(resource.id)

        let note = temp.service.activeNotesByID.values.first
        #expect(note?.text == "Trust & safety")
        #expect(note?.textResourceID == nil)
        #expect(temp.store.textResources.isEmpty)
    }

    @Test func textUsesListOneRowPerNote() throws {
        let temp = try TemporaryStore()
        let resource = temp.store.addTextResource("Code")!
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 100, y: 100))
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 500, y: 300))

        let uses = temp.store.textUses(of: resource.id)
        #expect(uses.count == 2)
        #expect(uses.allSatisfy { $0.isOnActiveBoard })
        // Each row knows where its note sits, so Locate has somewhere to go.
        #expect(Set(uses.map(\.worldPoint)).count == 2)
    }

    @Test func aNoteCarriesItsLibraryLinkWhenDuplicated() throws {
        let temp = try TemporaryStore()
        let resource = temp.store.addTextResource("Code")!
        temp.store.placeTextResource(resource.id, atWorld: CGPoint(x: 100, y: 100))
        let noteID = temp.service.activeNotesByID.keys.first!

        let clones = temp.service.duplicateNotes(sourceIDs: [noteID])

        #expect(clones.count == 1)
        #expect(temp.service.activeNotesByID[clones[0]]?.textResourceID == resource.id)
        #expect(temp.service.activeNotesByID[clones[0]]?.text == "Code")
    }

    // MARK: - Every note is a library item

    @Test func aNoteJoinsTheLibraryAsSoonAsItHasText() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!

        // Born empty, so nothing in the library yet: blank entries would be
        // worse than useless.
        #expect(temp.store.textResources.isEmpty)
        #expect(temp.service.activeNotesByID[noteID]?.textResourceID == nil)

        temp.service.updateNoteText(noteID: noteID, text: "Trust & safety")

        #expect(temp.store.textResources.count == 1)
        #expect(temp.store.textResources[0].text == "Trust & safety")
        #expect(temp.service.activeNotesByID[noteID]?.textResourceID != nil)
    }

    @Test func aWhitespaceOnlyNoteDoesNotJoin() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!

        temp.service.updateNoteText(noteID: noteID, text: "   \n  ")

        #expect(temp.store.textResources.isEmpty)
    }

    @Test func laterEditsGoToTheSameItemRatherThanMakingMore() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        temp.service.onTextResourceEdited = { temp.store.noteTextResourceEdited($0, text: $1) }
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!

        temp.service.updateNoteText(noteID: noteID, text: "T")
        let resourceID = temp.store.textResources[0].id
        temp.service.updateNoteText(noteID: noteID, text: "Trust")
        temp.service.updateNoteText(noteID: noteID, text: "Trust & safety")

        #expect(temp.store.textResources.count == 1)
        #expect(temp.store.textResources[0].id == resourceID)
        #expect(temp.store.textResources[0].text == "Trust & safety")
    }

    /// Two notes that happen to say the same thing are *not* linked. Linking
    /// them would mean an edit to one silently rewriting the other.
    @Test func twoNotesWithTheSameWordsStayIndependent() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        let first = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        let second = temp.service.createNote(atWorldCenter: CGPoint(x: 400, y: 0), colour: 0)!

        temp.service.updateNoteText(noteID: first, text: "TODO")
        temp.service.updateNoteText(noteID: second, text: "TODO")
        #expect(temp.store.textResources.count == 2)

        temp.service.updateNoteText(noteID: first, text: "TODO later")

        #expect(temp.service.activeNotesByID[second]?.text == "TODO")
    }

    @Test func existingNotesAreAdoptedOnLoad() throws {
        let temp = try TemporaryStore()
        let context = temp.service.context!
        let board = (try context.fetch(FetchDescriptor<BoardEntity>())).first!
        for text in ["Trust", "Safety", ""] {
            let note = NoteEntity(text: text, colour: 0, board: board)
            context.insert(note)
            board.notes.append(note)
        }
        try context.save()

        temp.store.loadLibraryForActiveProject()

        // The two with words joined; the empty one did not.
        #expect(temp.store.textResources.count == 2)
        #expect(Set(temp.store.textResources.map(\.text)) == ["Trust", "Safety"])
    }

    @Test func adoptingNotesOnLoadIsIdempotent() throws {
        let temp = try TemporaryStore()
        let context = temp.service.context!
        let board = (try context.fetch(FetchDescriptor<BoardEntity>())).first!
        let note = NoteEntity(text: "Trust", colour: 0, board: board)
        context.insert(note)
        board.notes.append(note)
        try context.save()

        temp.store.loadLibraryForActiveProject()
        let ids = temp.store.textResources.map(\.id)
        temp.store.loadLibraryForActiveProject()
        temp.store.loadLibraryForActiveProject()

        #expect(temp.store.textResources.map(\.id) == ids)
        #expect(try context.fetch(FetchDescriptor<TextResourceEntity>()).count == 1)
    }

    @Test func adoptionNeverChangesWhatANoteSays() throws {
        let temp = try TemporaryStore()
        let context = temp.service.context!
        let board = (try context.fetch(FetchDescriptor<BoardEntity>())).first!
        let note = NoteEntity(text: "Exactly these words", colour: 2, board: board)
        context.insert(note)
        board.notes.append(note)
        try context.save()

        temp.store.loadLibraryForActiveProject()

        #expect(temp.service.activeNotesByID[note.id]?.text == "Exactly these words")
        #expect(temp.service.activeNotesByID[note.id]?.colour == 2)
    }

    // MARK: - The chip only when sharing is real

    @Test func aNoteOnItsOwnIsNotMarkedAsShared() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        temp.service.updateNoteText(noteID: noteID, text: "Trust")

        let resourceID = temp.service.activeNotesByID[noteID]?.textResourceID
        #expect(temp.store.textUseCount(resourceID!) == 1)
        // Every note is an item, so a badge on all of them would say nothing.
        #expect(!temp.store.noteIsSharedWithAnotherPlace(resourceID))
    }

    @Test func aNoteUsedTwiceIsMarkedAsShared() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        temp.service.updateNoteText(noteID: noteID, text: "Trust")
        let resourceID = temp.service.activeNotesByID[noteID]!.textResourceID!

        temp.store.placeTextResource(resourceID, atWorld: CGPoint(x: 500, y: 0))

        #expect(temp.store.textUseCount(resourceID) == 2)
        #expect(temp.store.noteIsSharedWithAnotherPlace(resourceID))
    }

    @Test func deletingOneOfTwoSharedNotesDropsTheCount() throws {
        let temp = try TemporaryStore()
        temp.service.onLibraryChanged = { temp.store.reloadTextResources() }
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        temp.service.updateNoteText(noteID: noteID, text: "Trust")
        let resourceID = temp.service.activeNotesByID[noteID]!.textResourceID!
        temp.store.placeTextResource(resourceID, atWorld: CGPoint(x: 500, y: 0))
        #expect(temp.store.textUseCount(resourceID) == 2)

        temp.service.deleteNotes([noteID])

        #expect(temp.store.textUseCount(resourceID) == 1)
        // The item itself stays — removing a note is not removing the code.
        #expect(temp.store.textResources.count == 1)
    }

    @Test func resourcesAreScopedToTheirProject() throws {
        let temp = try TemporaryStore()
        _ = temp.store.addTextResource("In first project")
        #expect(temp.store.textResources.count == 1)

        temp.service.createProject()
        temp.store.activeProjectID = temp.service.activeProjectID
        temp.store.loadLibraryForActiveProject()

        #expect(temp.store.textResources.isEmpty)
    }
}

@MainActor
struct NoteInspectorTests {

    /// The stamp used to be @State on the card, so it was never saved and a
    /// recycled view lost it. It is a real control now, so it has to survive.
    @Test func aStampSurvivesAReopen() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        temp.store.selectNote(noteID)
        temp.store.setSelectedNoteStamp("lightbulb")

        #expect(temp.service.activeNotesByID[noteID]?.stamp == "lightbulb")

        let reread = try temp.reopen()
        let notes = try reread.fetch(FetchDescriptor<NoteEntity>())
        #expect(notes.first?.stamp == "lightbulb")
    }

    @Test func aStampCanBeCleared() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        temp.store.selectNote(noteID)
        temp.store.setSelectedNoteStamp("flame")
        temp.store.setSelectedNoteStamp(nil)
        #expect(temp.service.activeNotesByID[noteID]?.stamp == nil)
    }

    @Test func recolouringANoteSticks() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        temp.store.selectNote(noteID)
        temp.store.setSelectedNoteColour(2)

        #expect(temp.service.activeNotesByID[noteID]?.colour == 2)
        let reread = try temp.reopen()
        #expect(try reread.fetch(FetchDescriptor<NoteEntity>()).first?.colour == 2)
    }

    @Test func aDuplicateCarriesTheStamp() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 1)!
        temp.store.selectNote(noteID)
        temp.store.setSelectedNoteStamp("ladybug")

        let clones = temp.service.duplicateNotes(sourceIDs: [noteID])
        #expect(temp.service.activeNotesByID[clones[0]]?.stamp == "ladybug")
    }

    /// Only one thing is selected at a time, or Delete and Escape have no
    /// unambiguous target.
    @Test func selectingANoteClearsEveryOtherSelection() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        let asset = temp.placeImage()!
        temp.store.selectImage(asset.id)
        #expect(temp.store.selectedImageID != nil)

        temp.store.selectNote(noteID)
        #expect(temp.store.selectedNoteID == noteID)
        #expect(temp.store.selectedImageID == nil)

        temp.store.selectImage(asset.id)
        #expect(temp.store.selectedNoteID == nil)
    }

    @Test func escapeDeselectsANote() throws {
        let temp = try TemporaryStore()
        let noteID = temp.service.createNote(atWorldCenter: .zero, colour: 0)!
        temp.store.selectNote(noteID)
        #expect(temp.store.handleEscape())
        #expect(temp.store.selectedNoteID == nil)
    }

    @Test func everyStampSymbolHasAReadableName() {
        for symbol in NoteStamp.symbols {
            let name = NoteStamp.name(for: symbol)
            // A menu reading "text.bubble" is what this guards against.
            #expect(!name.contains("."))
            #expect(!name.isEmpty)
        }
    }
}
