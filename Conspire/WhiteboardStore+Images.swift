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

/// An imported image's bytes: what the user gave us, and what we draw.
struct ImageBlobs {
    let original: Data
    let display: Data
}

/// Enough to put the images back as they were.
///
/// Pins and links come along because deleting an image takes its pins and
/// every string attached to them; restoring the picture without the
/// annotations would be worse than not restoring it at all. `blobs` carries
/// bytes only for images the action removed, since restoring one of those
/// means recreating an entity that no longer exists — a move or a resize needs
/// no bytes.
struct ImageUndoState {
    var assets: [ImageAsset]
    var pins: [UUID: ImagePin]
    var links: [LinkID: Link]
    var blobs: [UUID: ImageBlobs] = [:]
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
            Task { [weak self] in
                guard let prepared = await ImageCodec.prepare(contentsOf: url) else { return }
                self?.insertImage(prepared, atWorld: drop)
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
            self?.insertImage(prepared, atWorld: worldCenter)
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

    private func insertImage(_ prepared: PreparedImage, atWorld worldCenter: CGPoint) {
        let before = imageUndoSnapshot()
        let asset = ImageAsset(
            worldRect: ImageAsset.importRect(
                centeredAt: worldCenter,
                pixelSize: prepared.nativePixelSize,
                longEdge: WhiteboardStyle.imageImportLongEdge
            ),
            zOrder: (images.map(\.zOrder).max() ?? -1) + 1,
            nativePixelSize: prepared.nativePixelSize,
            displayPixelCap: prepared.displayPixelCap
        )
        images.append(asset)
        imageContents[asset.id] = ImageCodec.decode(prepared.displayData)
        insertImageEntity(
            asset,
            blobs: ImageBlobs(original: prepared.originalData, display: prepared.displayData)
        )
        selectedImageID = asset.id
        registerImageUndo(before, actionName: "Add Image")
        appendActionLog("image added")
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

    func deleteImage(_ id: UUID) {
        guard images.contains(where: { $0.id == id }) else { return }
        // The bytes have to be captured before the entity goes, or undo has
        // nothing to restore the image from.
        var before = imageUndoSnapshot()
        if let blobs = imageBlobs(for: id) {
            before.blobs[id] = blobs
        }
        removePins(forImage: id)
        images.removeAll { $0.id == id }
        imageContents.removeValue(forKey: id)
        deleteImageEntity(id: id)
        if selectedImageID == id { selectedImageID = nil }
        registerImageUndo(before, actionName: "Delete Image")
        appendActionLog("image deleted")
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
    func resampleImage(_ id: UUID) {
        guard let asset = image(withID: id), let blobs = imageBlobs(for: id) else { return }
        let cap = neededImageCap(for: asset)
        guard cap != asset.displayPixelCap else { return }

        Task { [weak self] in
            let rebuilt = await Task.detached(priority: .userInitiated) {
                ImageCodec.downscaled(blobs.original, longEdgeCap: cap)
            }.value
            guard let rebuilt, let self else { return }
            self.applyResampled(id: id, cap: cap, displayData: rebuilt.data)
        }
    }

    private func applyResampled(id: UUID, cap: Int, displayData: Data) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].displayPixelCap = cap
        images[index].updatedAt = Date()
        imageContents[id] = ImageCodec.decode(displayData)
        if let entity = imageEntity(id: id) {
            entity.displayData = displayData
            entity.apply(images[index])
            try? persistence?.context?.save()
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
            var beforeThisUndo = target.imageUndoSnapshot()
            // Anything this undo is about to remove needs its bytes kept, so
            // the matching redo can bring it back.
            for asset in target.images where !stateToRestore.assets.contains(where: { $0.id == asset.id }) {
                if let blobs = target.imageBlobs(for: asset.id) {
                    beforeThisUndo.blobs[asset.id] = blobs
                }
            }
            target.applyImageUndo(stateToRestore)
            target.registerImageUndo(beforeThisUndo, actionName: actionName)
        }
        manager.setActionName(actionName)
    }

    private func applyImageUndo(_ state: ImageUndoState) {
        images = state.assets
        pins = state.pins
        links = state.links
        persistAllImages(restoring: state.blobs)
        persistAllPins()
        reconcileLinkEntities()

        // Decode anything that came back from the dead, drop anything gone.
        for asset in images where imageContents[asset.id] == nil {
            if let blobs = state.blobs[asset.id] ?? imageBlobs(for: asset.id) {
                imageContents[asset.id] = ImageCodec.decode(blobs.display)
            }
        }
        let live = Set(images.map(\.id))
        for id in imageContents.keys where !live.contains(id) {
            imageContents.removeValue(forKey: id)
        }
        if let selected = selectedImageID, !live.contains(selected) {
            selectedImageID = nil
        }
    }

    // MARK: - Persistence

    func loadImagesForActiveBoard() {
        guard let context = persistence?.context, let boardID = activeBoardID else {
            images = []
            imageContents = [:]
            return
        }
        let predicate = #Predicate<ImageEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<ImageEntity>(predicate: predicate))) ?? []
        images = entities.map { $0.toAsset() }.sorted { $0.zOrder < $1.zOrder }

        // One decode per image, off the main actor, so opening a board with a
        // dozen pictures does not stall the first frame.
        let payloads = entities.map { (id: $0.id, data: $0.displayData) }
        imageContents = [:]
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                payloads.compactMap { payload -> (UUID, CGImage)? in
                    guard let image = ImageCodec.decode(payload.data) else { return nil }
                    return (payload.id, image)
                }
            }.value
            guard let self else { return }
            // The board may have changed while we were decoding.
            let live = Set(self.images.map(\.id))
            for (id, image) in decoded where live.contains(id) {
                self.imageContents[id] = image
            }
        }
    }

    func imageEntity(id: UUID) -> ImageEntity? {
        guard let context = persistence?.context else { return nil }
        let targetID = id
        let predicate = #Predicate<ImageEntity> { $0.id == targetID }
        return try? context.fetch(FetchDescriptor<ImageEntity>(predicate: predicate)).first
    }

    func imageBlobs(for id: UUID) -> ImageBlobs? {
        guard let entity = imageEntity(id: id) else { return nil }
        return ImageBlobs(original: entity.originalData, display: entity.displayData)
    }

    func insertImageEntity(_ asset: ImageAsset, blobs: ImageBlobs) {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        context.insert(
            ImageEntity(
                boardID: boardID,
                asset: asset,
                originalData: blobs.original,
                displayData: blobs.display
            )
        )
        try? context.save()
    }

    /// Geometry only — the bytes never change outside import and resample.
    func persistImage(_ asset: ImageAsset) {
        guard let entity = imageEntity(id: asset.id) else { return }
        entity.apply(asset)
        try? persistence?.context?.save()
    }

    /// Reconciles the whole set after an undo replaced `images` wholesale.
    func persistAllImages(restoring blobs: [UUID: ImageBlobs]) {
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
            } else if let blobs = blobs[asset.id] {
                context.insert(
                    ImageEntity(
                        boardID: boardID,
                        asset: asset,
                        originalData: blobs.original,
                        displayData: blobs.display
                    )
                )
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
