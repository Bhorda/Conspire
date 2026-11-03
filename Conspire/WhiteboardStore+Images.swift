//
//  WhiteboardStore+Images.swift
//  Conspire
//

import AppKit
import CoreGraphics
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// What a drag on an image is doing. Moving keeps the grab offset so the image
/// does not jump to the cursor; resizing only ever needs the rect it started at.
enum ImageGesture {
    case move(id: UUID, startRect: CGRect, grabWorldOffset: CGSize)
    case resize(id: UUID, startRect: CGRect)

    var imageID: UUID {
        switch self {
        case .move(let id, _, _): return id
        case .resize(let id, _): return id
        }
    }
}

/// Enough to put the placements back as they were.
///
/// Pins and links come along because deleting a placement takes its pins and
/// every string attached to them; restoring the picture without the
/// annotations would be worse than not restoring it at all. No bytes are
/// needed any more — those belong to the resource, which a deleted placement
/// does not take with it.
struct ImageUndoState {
    var assets: [ImageAsset]
    var pins: [UUID: ImagePin]
    var links: [LinkID: Link]
}

extension WhiteboardStore {

    // MARK: - Lookup

    func image(withID id: UUID?) -> ImageAsset? {
        guard let id else { return nil }
        return images.first { $0.id == id }
    }

    /// Topmost image under a world point, matching draw order.
    func image(atWorld point: CGPoint) -> ImageAsset? {
        images
            .filter { $0.worldRect.contains(point) }
            .max { $0.zOrder < $1.zOrder }
    }

    func selectImage(_ id: UUID?) {
        selectedImageID = id
        if id != nil { selectedNoteID = nil }
    }

    /// A click on an image, with where on the image it landed.
    ///
    /// The position only matters to the string tool, which is the whole reason
    /// it is threaded through: a string attaches to the point you clicked, not
    /// to the picture.
    func handleImageTap(_ id: UUID, atNormalised position: (u: CGFloat, v: CGFloat)) {
        if placementMode == .string {
            pinAndLink(imageID: id, u: position.u, v: position.v)
            return
        }
        selectLink(nil)
        selectField(nil)
        selectImage(id)
    }

    // MARK: - Import

    /// Preparing is decode-bound, so it happens off the main actor and the
    /// asset appears when it is ready. Several files fan out slightly instead
    /// of landing exactly on top of each other.
    func importImages(from urls: [URL], atWorld worldCenter: CGPoint) {
        for (index, url) in urls.enumerated() {
            let drop = CGPoint(
                x: worldCenter.x + CGFloat(index) * 24,
                y: worldCenter.y + CGFloat(index) * 24
            )
            let name = url.deletingPathExtension().lastPathComponent
            Task { [weak self] in
                guard let prepared = await ImageCodec.prepare(contentsOf: url) else { return }
                self?.insertImage(prepared, named: name, atWorld: drop)
            }
        }
    }

    func importImageFromPasteboard(atWorld worldCenter: CGPoint) {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            importImages(from: urls.filter { $0.isFileURL }, atWorld: worldCenter)
            return
        }
        // Bitmap on the clipboard (a screenshot, a copied web image) has no
        // file to read, so the TIFF representation is the original.
        guard let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) else {
            return
        }
        Task { [weak self] in
            guard let prepared = await ImageCodec.prepare(data: data) else { return }
            self?.insertImage(prepared, named: "Pasted image", atWorld: worldCenter)
        }
    }

    func presentImageImporter(atWorld worldCenter: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        importImages(from: panel.urls, atWorld: worldCenter)
    }

    /// An import is two things: a new picture in the project's library, and a
    /// first placement of it on this board.
    private func insertImage(_ prepared: PreparedImage, named name: String, atWorld worldCenter: CGPoint) {
        guard let resource = addImageResource(prepared, name: name) else { return }
        placeImageResource(resource.id, atWorld: worldCenter)
    }

    // MARK: - Gestures

    func beginImageMove(id: UUID, atWorld point: CGPoint) {
        guard let asset = image(withID: id) else { return }
        imageGesture = .move(
            id: id,
            startRect: asset.worldRect,
            grabWorldOffset: CGSize(
                width: point.x - asset.worldRect.minX,
                height: point.y - asset.worldRect.minY
            )
        )
        imageUndoBeforeGesture = imageUndoSnapshot()
        selectedImageID = id
    }

    func beginImageResize(id: UUID) {
        guard let asset = image(withID: id) else { return }
        imageGesture = .resize(id: id, startRect: asset.worldRect)
        imageUndoBeforeGesture = imageUndoSnapshot()
        selectedImageID = id
    }

    func updateImageGesture(atWorld point: CGPoint) {
        guard let gesture = imageGesture,
              let index = images.firstIndex(where: { $0.id == gesture.imageID })
        else { return }

        switch gesture {
        case .move(_, let startRect, let grab):
            images[index].worldRect = CGRect(
                origin: CGPoint(x: point.x - grab.width, y: point.y - grab.height),
                size: startRect.size
            )
        case .resize:
            images[index].worldRect = images[index].resized(
                toCornerWorld: point,
                minimumLongEdge: WhiteboardStyle.imageMinimumLongEdge
            )
        }
    }

    func endImageGesture() {
        guard let gesture = imageGesture else { return }
        imageGesture = nil
        guard let asset = image(withID: gesture.imageID) else {
            imageUndoBeforeGesture = nil
            return
        }
        var updated = asset
        updated.updatedAt = Date()
        if let index = images.firstIndex(where: { $0.id == asset.id }) {
            images[index] = updated
        }
        persistImage(updated)
        if let before = imageUndoBeforeGesture {
            let name: String
            switch gesture {
            case .move: name = "Move Image"
            case .resize: name = "Resize Image"
            }
            registerImageUndo(before, actionName: name)
        }
        imageUndoBeforeGesture = nil
    }

    func cancelImageGesture() {
        guard let gesture = imageGesture else { return }
        if let index = images.firstIndex(where: { $0.id == gesture.imageID }) {
            switch gesture {
            case .move(_, let startRect, _), .resize(_, let startRect):
                images[index].worldRect = startRect
            }
        }
        imageGesture = nil
        imageUndoBeforeGesture = nil
    }

    // MARK: - Ordering and deletion

    func bringImageToFront(_ id: UUID) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let top = images.map(\.zOrder).max() ?? 0
        guard images[index].zOrder != top else { return }
        let before = imageUndoSnapshot()
        images[index].zOrder = top + 1
        images[index].updatedAt = Date()
        persistImage(images[index])
        registerImageUndo(before, actionName: "Bring Image to Front")
    }

    func deleteSelectedImage() {
        guard let id = selectedImageID else { return }
        deleteImage(id)
    }

    /// Removes one appearance of a picture. The picture stays in the library —
    /// taking a placement off a board is not the same as throwing the photo
    /// away, and the library has its own delete for that.
    func deleteImage(_ id: UUID) {
        guard images.contains(where: { $0.id == id }) else { return }
        let before = imageUndoSnapshot()
        removePins(forImage: id)
        images.removeAll { $0.id == id }
        deleteImageEntity(id: id)
        if selectedImageID == id { selectedImageID = nil }
        registerImageUndo(before, actionName: "Delete Image")
        appendActionLog("image placement deleted")
    }

    // MARK: - Resample

    /// The display cap that would make this image sharp at its current size.
    func neededImageCap(for asset: ImageAsset) -> Int {
        ImageCodec.neededCap(
            forWorldLongEdge: asset.worldLongEdge * canvasScale,
            nativeLongEdge: asset.nativeLongEdge
        )
    }

    func canResampleImage(_ asset: ImageAsset) -> Bool {
        ImageCodec.resampleWorthwhile(
            currentCap: asset.displayPixelCap,
            neededCap: neededImageCap(for: asset)
        )
    }

    /// Rebuild the display asset from the original at the size the image is
    /// actually being shown. Deliberately manual: it is the one place the
    /// one-decode-per-image rule is allowed to be broken, and only on request.
    /// Rebuild the picture's display asset from its original at the size it is
    /// being shown. The *decision* comes from this placement, but the result
    /// belongs to the resource, so every board showing the picture gets the
    /// sharper version — which is right: the asset is what was short of pixels.
    func resampleImage(_ id: UUID) {
        guard let asset = image(withID: id),
              let entity = imageResourceEntity(id: asset.resourceID)
        else { return }
        let original = entity.originalData
        let cap = neededImageCap(for: asset)
        guard cap != asset.displayPixelCap else { return }

        Task { [weak self] in
            let rebuilt = await Task.detached(priority: .userInitiated) {
                ImageCodec.downscaled(original, longEdgeCap: cap)
            }.value
            guard let rebuilt, let self else { return }
            self.applyResampled(resourceID: asset.resourceID, cap: cap, displayData: rebuilt.data)
        }
    }

    private func applyResampled(resourceID: UUID, cap: Int, displayData: Data) {
        guard let entity = imageResourceEntity(id: resourceID) else { return }
        entity.displayData = displayData
        entity.displayPixelCap = cap
        entity.updatedAt = .now
        try? persistence?.context?.save()

        imageContents[resourceID] = ImageCodec.decode(displayData)
        if let index = imageResources.firstIndex(where: { $0.id == resourceID }) {
            imageResources[index].displayPixelCap = cap
        }
        // Every placement of this picture on the open board follows.
        for index in images.indices where images[index].resourceID == resourceID {
            images[index].displayPixelCap = cap
            images[index].updatedAt = Date()
        }
        appendActionLog("image resampled to \(cap)px")
    }

    // MARK: - Undo

    func imageUndoSnapshot() -> ImageUndoState {
        ImageUndoState(assets: images, pins: pins, links: links)
    }

    func registerImageUndo(_ stateToRestore: ImageUndoState, actionName: String) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            let beforeThisUndo = target.imageUndoSnapshot()
            target.applyImageUndo(stateToRestore)
            target.registerImageUndo(beforeThisUndo, actionName: actionName)
        }
        manager.setActionName(actionName)
    }

    private func applyImageUndo(_ state: ImageUndoState) {
        images = state.assets
        pins = state.pins
        links = state.links
        persistAllImages()
        persistAllPins()
        reconcileLinkEntities()

        // A placement restored by undo may be of a picture whose decode was
        // dropped; the bytes are still on the resource either way.
        for asset in images { ensureDecoded(asset.resourceID) }
        if let selected = selectedImageID, !images.contains(where: { $0.id == selected }) {
            selectedImageID = nil
        }
    }

    // MARK: - Persistence

    func loadImagesForActiveBoard() {
        guard let context = persistence?.context, let boardID = activeBoardID else {
            images = []
            return
        }
        migrateImagePlacementsToResources()

        let predicate = #Predicate<ImageEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<ImageEntity>(predicate: predicate))) ?? []
        var byID: [UUID: ImageResource] = [:]
        for resource in imageResources { byID[resource.id] = resource }

        images = entities
            .map { entity in entity.toAsset(resource: entity.resourceID.flatMap { byID[$0] }) }
            .sorted { $0.zOrder < $1.zOrder }

        // One decode per *picture*, off the main actor, so opening a board with
        // a dozen of them does not stall the first frame — and a picture shown
        // on two boards is only ever decoded once.
        let wanted = Set(images.map(\.resourceID)).filter { imageContents[$0] == nil }
        guard !wanted.isEmpty else { return }
        let payloads = wanted.compactMap { id -> (UUID, Data)? in
            guard let entity = imageResourceEntity(id: id) else { return nil }
            return (id, entity.displayData)
        }
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                payloads.compactMap { payload -> (UUID, CGImage)? in
                    guard let image = ImageCodec.decode(payload.1) else { return nil }
                    return (payload.0, image)
                }
            }.value
            guard let self else { return }
            for (id, image) in decoded {
                self.imageContents[id] = image
            }
        }
    }

    /// Placements written before the library existed carry their own bytes and
    /// no resource. Each one gets a resource minted from those bytes.
    ///
    /// Idempotent, keyed on `resourceID == nil`. The resource is written and
    /// saved *before* the placement is pointed at it, and the placement's
    /// legacy blobs are never cleared — so an interruption at any point leaves
    /// the bytes readable from at least one place, and a second run picks up
    /// where it stopped.
    func migrateImagePlacementsToResources() {
        guard let context = persistence?.context, activeProjectID != nil else { return }
        let stale = (try? context.fetch(
            FetchDescriptor<ImageEntity>(predicate: #Predicate { $0.resourceID == nil })
        )) ?? []
        guard !stale.isEmpty else { return }

        for placement in stale where !placement.displayData.isEmpty {
            let prepared = PreparedImage(
                originalData: placement.originalData.isEmpty
                    ? placement.displayData
                    : placement.originalData,
                displayData: placement.displayData,
                thumbnailData: ImageCodec.downscaled(
                    placement.displayData, longEdgeCap: ImageCodec.thumbnailCap
                )?.data ?? placement.displayData,
                nativePixelSize: CGSize(
                    width: placement.nativeWidth, height: placement.nativeHeight
                ),
                displayPixelCap: placement.displayPixelCap
            )
            guard let resource = addImageResource(prepared, name: "Image") else { continue }
            placement.resourceID = resource.id
            try? context.save()
        }
        appendActionLog("migrated \(stale.count) image placement(s) to the library")
    }

    func insertImagePlacement(_ asset: ImageAsset) {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        context.insert(ImageEntity(boardID: boardID, asset: asset))
        try? context.save()
    }

    func imageEntity(id: UUID) -> ImageEntity? {
        guard let context = persistence?.context else { return nil }
        let targetID = id
        let predicate = #Predicate<ImageEntity> { $0.id == targetID }
        return try? context.fetch(FetchDescriptor<ImageEntity>(predicate: predicate)).first
    }

    /// Geometry only — the bytes belong to the resource.
    func persistImage(_ asset: ImageAsset) {
        guard let entity = imageEntity(id: asset.id) else { return }
        entity.apply(asset)
        try? persistence?.context?.save()
    }

    /// Reconciles the whole set after an undo replaced `images` wholesale.
    /// A placement can be recreated outright now — it is only a rect and a
    /// resource id, so undoing a delete needs nothing that was thrown away.
    func persistAllImages() {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        let predicate = #Predicate<ImageEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<ImageEntity>(predicate: predicate))) ?? []
        var existing: [UUID: ImageEntity] = [:]
        for entity in entities { existing[entity.id] = entity }

        let live = Set(images.map(\.id))
        for entity in entities where !live.contains(entity.id) {
            context.delete(entity)
        }
        for asset in images {
            if let entity = existing[asset.id], !entity.isDeleted {
                entity.apply(asset)
            } else {
                context.insert(ImageEntity(boardID: boardID, asset: asset))
            }
        }
        try? context.save()
    }

    func deleteImageEntity(id: UUID) {
        guard let context = persistence?.context, let entity = imageEntity(id: id) else { return }
        context.delete(entity)
        try? context.save()
    }
}
