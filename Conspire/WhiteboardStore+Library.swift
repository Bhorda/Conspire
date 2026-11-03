//
//  WhiteboardStore+Library.swift
//  Conspire
//

import AppKit
import CoreGraphics
import SwiftUI
import Foundation
import SwiftData

/// The project's shared resources, and the placements that use them.
///
/// Every image on any board in the project is a resource here, so the library
/// is a complete inventory rather than a curated subset — which means there is
/// no "add to library" step and nothing to keep in sync.
extension WhiteboardStore {

    // MARK: - Loading

    func loadLibraryForActiveProject() {
        guard let context = persistence?.context, let projectID = activeProjectID else {
            imageResources = []
            textResources = []
            imageThumbnails = [:]
            textResourceUseCounts = [:]
            return
        }
        // Notes written before the library existed join it here.
        persistence?.adoptNotesIntoLibrary()

        let imagePredicate = #Predicate<ImageResourceEntity> { $0.projectID == projectID }
        let imageRows = (try? context.fetch(
            FetchDescriptor<ImageResourceEntity>(predicate: imagePredicate)
        )) ?? []
        imageResources = imageRows.map { $0.toResource() }.sorted { $0.createdAt > $1.createdAt }

        let textPredicate = #Predicate<TextResourceEntity> { $0.projectID == projectID }
        let textRows = (try? context.fetch(
            FetchDescriptor<TextResourceEntity>(predicate: textPredicate)
        )) ?? []
        textResources = textRows.map { $0.toResource() }.sorted { $0.createdAt > $1.createdAt }
        syncTextLookup()

        decodeThumbnails(from: imageRows.map { (id: $0.id, data: $0.thumbnailData) })
        rebuildTextUseCounts()
    }

    /// Patches one item's words in place. Called per keystroke, so it must not
    /// fetch: the set of items has not changed, only what one of them says.
    func noteTextResourceEdited(_ id: UUID, text: String) {
        guard let index = textResources.firstIndex(where: { $0.id == id }) else { return }
        guard textResources[index].text != text else { return }
        textResources[index].text = text
        persistence?.textResourceLookup[id] = text
    }

    /// Hands the persistence side the words it needs to resolve notes, so that
    /// resolution is a dictionary read rather than a fetch per keystroke.
    private func syncTextLookup() {
        persistence?.textResourceLookup = Dictionary(
            textResources.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first }
        )
    }

    /// Reloads only the text items and their counts — what changes when a note
    /// joins the library, or notes are duplicated or deleted.
    func reloadTextResources() {
        guard let context = persistence?.context, let projectID = activeProjectID else { return }
        let predicate = #Predicate<TextResourceEntity> { $0.projectID == projectID }
        let rows = (try? context.fetch(
            FetchDescriptor<TextResourceEntity>(predicate: predicate)
        )) ?? []
        textResources = rows.map { $0.toResource() }.sorted { $0.createdAt > $1.createdAt }
        syncTextLookup()
        rebuildTextUseCounts()
    }

    /// How many notes each text item is on, cached.
    ///
    /// Every note is a library item now, so this is read once per note card and
    /// once per library row. Counting it there would be a fetch per row per
    /// render — the same mistake field membership made before it was cached.
    func rebuildTextUseCounts() {
        guard let context = persistence?.context, let projectID = activeProjectID else {
            textResourceUseCounts = [:]
            return
        }
        // Fetched by link rather than walked board by board. Going through
        // `board.notes` faults every note in the project, which measured at
        // ~5.8ms for sixty and scales with the whole project; this only reads
        // the notes that actually carry a link.
        // Optionals all the way through: a `#Predicate` body is one
        // expression, so the comparison has to be against optional ids rather
        // than unwrapping inside it.
        let ids: [UUID?] = textResources.map { $0.id }
        guard !ids.isEmpty else {
            textResourceUseCounts = [:]
            return
        }
        let linked = (try? context.fetch(FetchDescriptor<NoteEntity>(
            predicate: #Predicate { ids.contains($0.textResourceID) }
        ))) ?? []
        var counts: [UUID: Int] = [:]
        for note in linked {
            if let id = note.textResourceID { counts[id, default: 0] += 1 }
        }
        textResourceUseCounts = counts
    }

    func textUseCount(_ resourceID: UUID) -> Int {
        textResourceUseCounts[resourceID] ?? 0
    }

    /// True when editing this note's words would change another board too —
    /// the only case where the library link is worth telling the user about.
    func noteIsSharedWithAnotherPlace(_ resourceID: UUID?) -> Bool {
        guard let resourceID else { return false }
        return textUseCount(resourceID) > 1
    }

    /// Thumbnails decode off the main actor and arrive together. They are small
    /// — 256px — so a library of fifty costs a few milliseconds rather than the
    /// ~160ms of re-decoding fifty display assets.
    private func decodeThumbnails(from payloads: [(id: UUID, data: Data)]) {
        let wanted = payloads.filter { imageThumbnails[$0.id] == nil }
        guard !wanted.isEmpty else { return }
        Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) {
                wanted.compactMap { payload -> (UUID, CGImage)? in
                    guard let image = ImageCodec.decode(payload.data) else { return nil }
                    return (payload.id, image)
                }
            }.value
            guard let self else { return }
            for (id, image) in decoded {
                self.imageThumbnails[id] = image
            }
        }
    }

    // MARK: - Image resources

    func imageResourceEntity(id: UUID) -> ImageResourceEntity? {
        guard let context = persistence?.context else { return nil }
        let target = id
        let predicate = #Predicate<ImageResourceEntity> { $0.id == target }
        return try? context.fetch(FetchDescriptor<ImageResourceEntity>(predicate: predicate)).first
    }

    func imageResource(withID id: UUID?) -> ImageResource? {
        guard let id else { return nil }
        return imageResources.first { $0.id == id }
    }

    /// Adds a picture to the project. Returns the resource, or nil if the
    /// bytes could not be read.
    @discardableResult
    func addImageResource(_ prepared: PreparedImage, name: String) -> ImageResource? {
        guard let context = persistence?.context, let projectID = activeProjectID else { return nil }
        let entity = ImageResourceEntity(
            projectID: projectID,
            name: name,
            originalData: prepared.originalData,
            displayData: prepared.displayData,
            thumbnailData: prepared.thumbnailData,
            nativeWidth: prepared.nativePixelSize.width,
            nativeHeight: prepared.nativePixelSize.height,
            displayPixelCap: prepared.displayPixelCap
        )
        context.insert(entity)
        try? context.save()

        let resource = entity.toResource()
        imageResources.insert(resource, at: 0)
        imageContents[resource.id] = ImageCodec.decode(prepared.displayData)
        imageThumbnails[resource.id] = ImageCodec.decode(prepared.thumbnailData)
        return resource
    }

    /// Removes a picture from the project, and every placement of it.
    func deleteImageResource(_ id: UUID) {
        guard let context = persistence?.context else { return }
        let uses = imageUses(of: id)

        // Placements on the open board are in memory too.
        let doomed = images.filter { $0.resourceID == id }.map(\.id)
        for placementID in doomed { deleteImage(placementID) }

        // The rest are on other boards, so only their rows exist.
        let target = id
        for entity in (try? context.fetch(
            FetchDescriptor<ImageEntity>(predicate: #Predicate { $0.resourceID == target })
        )) ?? [] {
            purgePins(forImagePlacement: entity.id, boardID: entity.boardID)
            context.delete(entity)
        }
        if let entity = imageResourceEntity(id: id) { context.delete(entity) }
        try? context.save()

        imageResources.removeAll { $0.id == id }
        imageContents.removeValue(forKey: id)
        imageThumbnails.removeValue(forKey: id)
        appendActionLog("library image deleted (\(uses.count) use\(uses.count == 1 ? "" : "s"))")
    }

    /// Pins on a placement that is not on the open board have no in-memory
    /// state, so they and their strings are cleared by row.
    private func purgePins(forImagePlacement placementID: UUID, boardID: UUID) {
        guard let context = persistence?.context else { return }
        let target = placementID
        let pinRows = (try? context.fetch(
            FetchDescriptor<ImagePinEntity>(predicate: #Predicate { $0.imageID == target })
        )) ?? []
        guard !pinRows.isEmpty else { return }
        let pinIDs = Set(pinRows.map(\.id))
        let board = boardID
        for link in (try? context.fetch(
            FetchDescriptor<LinkEntity>(predicate: #Predicate { $0.boardID == board })
        )) ?? [] {
            let node = link.toLink()
            let touches = pinIDs.contains { node.from == .pin($0) || node.to == .pin($0) }
            if touches { context.delete(link) }
        }
        for pin in pinRows { context.delete(pin) }
    }

    // MARK: - Text resources

    @discardableResult
    func addTextResource(_ text: String) -> TextResource? {
        guard let context = persistence?.context, let projectID = activeProjectID else { return nil }
        let entity = TextResourceEntity(projectID: projectID, text: text)
        context.insert(entity)
        try? context.save()
        let resource = entity.toResource()
        textResources.insert(resource, at: 0)
        syncTextLookup()
        rebuildTextUseCounts()
        return resource
    }

    func textResource(withID id: UUID?) -> TextResource? {
        guard let id else { return nil }
        return textResources.first { $0.id == id }
    }

    func textResourceEntity(id: UUID) -> TextResourceEntity? {
        guard let context = persistence?.context else { return nil }
        let target = id
        let predicate = #Predicate<TextResourceEntity> { $0.id == target }
        return try? context.fetch(FetchDescriptor<TextResourceEntity>(predicate: predicate)).first
    }

    /// The edit that reaches every board. A note made from this resource shows
    /// the resource's text, so this is the only place that text changes.
    func updateTextResource(_ id: UUID, text: String) {
        guard let entity = textResourceEntity(id: id) else { return }
        entity.text = text
        entity.updatedAt = .now
        try? persistence?.context?.save()
        if let index = textResources.firstIndex(where: { $0.id == id }) {
            textResources[index].text = text
        }
        persistence?.textResourceLookup[id] = text
        // Notes on the open board read through to the resource, so the board
        // has to be rebuilt for the change to show.
        persistence?.refreshActiveBoard()
    }

    func deleteTextResource(_ id: UUID) {
        guard let context = persistence?.context else { return }
        let target = id
        for note in (try? context.fetch(
            FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.textResourceID == target })
        )) ?? [] {
            // The note stays, with the words it was last showing, rather than
            // going blank or vanishing from a board the user is not looking at.
            note.text = textResource(withID: id)?.text ?? note.text
            note.textResourceID = nil
        }
        if let entity = textResourceEntity(id: id) { context.delete(entity) }
        try? context.save()
        textResources.removeAll { $0.id == id }
        syncTextLookup()
        persistence?.refreshActiveBoard()
        rebuildTextUseCounts()
    }

    // MARK: - Uses

    /// Every appearance of a picture across the project, one row per placement.
    func imageUses(of resourceID: UUID) -> [ResourceUse] {
        guard let context = persistence?.context else { return [] }
        let target = resourceID
        let placements = (try? context.fetch(
            FetchDescriptor<ImageEntity>(predicate: #Predicate { $0.resourceID == target })
        )) ?? []
        let names = boardNames()
        return placements.compactMap { placement -> ResourceUse? in
            guard let boardName = names[placement.boardID] else { return nil }
            let rect = CGRect(
                x: placement.x, y: placement.y, width: placement.width, height: placement.height
            )
            return ResourceUse(
                id: placement.id,
                boardID: placement.boardID,
                boardName: boardName,
                worldPoint: CGPoint(x: rect.midX, y: rect.midY),
                isOnActiveBoard: placement.boardID == activeBoardID
            )
        }
        .sorted { ($0.boardName, $0.id.uuidString) < ($1.boardName, $1.id.uuidString) }
    }

    /// Every note made from a text resource. A note's world position comes from
    /// the group holding it, which is why the group blobs have to be decoded.
    func textUses(of resourceID: UUID) -> [ResourceUse] {
        guard let context = persistence?.context, let projectID = activeProjectID else { return [] }
        let target = resourceID
        let notes = (try? context.fetch(
            FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.textResourceID == target })
        )) ?? []
        guard !notes.isEmpty else { return [] }

        let boards = (try? context.fetch(
            FetchDescriptor<BoardEntity>(predicate: #Predicate { $0.projectID == projectID })
        )) ?? []

        var uses: [ResourceUse] = []
        for board in boards {
            let wanted = Set(notes.filter { $0.board?.id == board.id }.map(\.id))
            guard !wanted.isEmpty else { continue }
            for group in board.groups {
                let ids = NoteGroupEntity.decodeNoteIDs(group.noteIDsBlob)
                for (index, noteID) in ids.enumerated() where wanted.contains(noteID) {
                    let model = NoteGroup(
                        id: group.id,
                        anchor: CGPoint(x: group.anchorX, y: group.anchorY),
                        zOrder: group.zOrder,
                        noteIDs: ids
                    )
                    uses.append(
                        ResourceUse(
                            id: noteID,
                            boardID: board.id,
                            boardName: board.name,
                            worldPoint: BoardLayout.noteCenterWorld(group: model, noteIndex: index),
                            isOnActiveBoard: board.id == activeBoardID
                        )
                    )
                }
            }
        }
        return uses.sorted { ($0.boardName, $0.id.uuidString) < ($1.boardName, $1.id.uuidString) }
    }

    private func boardNames() -> [UUID: String] {
        guard let context = persistence?.context, let projectID = activeProjectID else { return [:] }
        let boards = (try? context.fetch(
            FetchDescriptor<BoardEntity>(predicate: #Predicate { $0.projectID == projectID })
        )) ?? []
        return Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0.name) })
    }

    // MARK: - Placing a resource on the board

    /// Drops a library picture onto the open board. Shares the resource's bytes
    /// and its decode — this is a second placement, not a second copy.
    func placeImageResource(_ resourceID: UUID, atWorld worldCenter: CGPoint) {
        guard let resource = imageResource(withID: resourceID) else { return }
        let before = imageUndoSnapshot()
        let asset = ImageAsset(
            resourceID: resourceID,
            worldRect: ImageAsset.importRect(
                centeredAt: worldCenter,
                pixelSize: resource.nativePixelSize,
                longEdge: WhiteboardStyle.imageImportLongEdge
            ),
            zOrder: (images.map(\.zOrder).max() ?? -1) + 1,
            nativePixelSize: resource.nativePixelSize,
            displayPixelCap: resource.displayPixelCap
        )
        images.append(asset)
        ensureDecoded(resourceID)
        insertImagePlacement(asset)
        selectedImageID = asset.id
        registerImageUndo(before, actionName: "Add Image")
        appendActionLog("image placed from library")
    }

    /// Makes a sticky note from a text resource where it was dropped. The note
    /// shows the resource's text rather than a copy of it.
    func placeTextResource(_ resourceID: UUID, atWorld worldCenter: CGPoint) {
        guard let resource = textResource(withID: resourceID) else { return }
        guard let noteID = persistence?.createNote(
            atWorldCenter: worldCenter,
            colour: resource.colour ?? noteColourPicked,
            textResourceID: resourceID
        ) else { return }
        rebuildTextUseCounts()
        appendActionLog("note placed from library \(noteID.uuidString.prefix(8))…")
    }

    /// Fills in a resource's display decode if it is not already in memory —
    /// placing a picture that lives on another board is the usual reason.
    func ensureDecoded(_ resourceID: UUID) {
        guard imageContents[resourceID] == nil else { return }
        guard let entity = imageResourceEntity(id: resourceID) else { return }
        let data = entity.displayData
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageCodec.decode(data)
            }.value
            guard let self, let decoded else { return }
            self.imageContents[resourceID] = decoded
        }
    }

    // MARK: - Locate

    /// Brings a use into view: switches board if it is on another one, then
    /// glides the canvas so the thing is in the middle.
    func locate(_ use: ResourceUse, viewportSize: CGSize) {
        if use.boardID != activeBoardID {
            persistence?.selectBoard(id: use.boardID)
            onBoardSwitched?()
        }
        focus(worldPoint: use.worldPoint, viewportSize: viewportSize)
    }

    /// The pan that puts a world point in the middle of the viewport.
    static func panCentring(
        worldPoint: CGPoint, viewportSize: CGSize, scale: CGFloat
    ) -> CGSize {
        CGSize(
            width: viewportSize.width / 2 - worldPoint.x * scale,
            height: viewportSize.height / 2 - worldPoint.y * scale
        )
    }

    func focus(worldPoint: CGPoint, viewportSize: CGSize) {
        let target = Self.panCentring(
            worldPoint: worldPoint, viewportSize: viewportSize, scale: canvasScale
        )
        withAnimation(.easeInOut(duration: 0.35)) {
            canvasPan = target
        }
    }
}
