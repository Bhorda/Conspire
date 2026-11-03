//
//  ImageModels.swift
//  Conspire
//

import CoreGraphics
import Foundation
import SwiftData

/// One appearance of a picture on a board — a *placement*.
///
/// `worldRect` is the whole of its position and size; images are not stacked or
/// grouped, so there is no layout to derive. The picture itself belongs to the
/// project as an `ImageResource`, which is what `resourceID` names, so two
/// placements of the same photo share its bytes and its decode.
///
/// `nativePixelSize` and `displayPixelCap` are copies of the resource's, filled
/// in when the board loads. The resource owns them — these are here so the
/// geometry and the resample check can be answered without a lookup on every
/// frame.
struct ImageAsset: Identifiable, Equatable {
    let id: UUID
    var resourceID: UUID
    var worldRect: CGRect
    var zOrder: Int
    /// Pixel size of the original, kept so a resample knows its ceiling.
    var nativePixelSize: CGSize
    var displayPixelCap: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        resourceID: UUID = UUID(),
        worldRect: CGRect,
        zOrder: Int,
        nativePixelSize: CGSize,
        displayPixelCap: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.resourceID = resourceID
        self.worldRect = worldRect
        self.zOrder = zOrder
        self.nativePixelSize = nativePixelSize
        self.displayPixelCap = displayPixelCap
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var aspect: CGFloat {
        guard nativePixelSize.width > 0, nativePixelSize.height > 0 else { return 1 }
        return nativePixelSize.width / nativePixelSize.height
    }

    var nativeLongEdge: CGFloat { max(nativePixelSize.width, nativePixelSize.height) }

    var worldLongEdge: CGFloat { max(worldRect.width, worldRect.height) }
}

/// A point on an image that a string can attach to.
///
/// Held in normalised image coordinates — `u` across, `v` down, both 0…1 — so
/// a pin follows its image through any move, resize or resample without being
/// recalculated. Everything else about pins follows from that.
struct ImagePin: Identifiable, Equatable {
    let id: UUID
    let imageID: UUID
    var u: CGFloat
    var v: CGFloat

    init(id: UUID = UUID(), imageID: UUID, u: CGFloat, v: CGFloat) {
        self.id = id
        self.imageID = imageID
        self.u = u
        self.v = v
    }
}

/// Dragging a pin to a different point on its image. The start position is
/// kept so Escape can put it back.
struct PinGesture {
    let id: UUID
    let startU: CGFloat
    let startV: CGFloat
}

extension ImageAsset {
    /// Where a normalised point sits in world space.
    func worldPoint(u: CGFloat, v: CGFloat) -> CGPoint {
        CGPoint(x: worldRect.minX + u * worldRect.width, y: worldRect.minY + v * worldRect.height)
    }

    func worldPoint(of pin: ImagePin) -> CGPoint {
        worldPoint(u: pin.u, v: pin.v)
    }

    /// The normalised position of a world point, clamped to the image so a pin
    /// dragged past the edge stays on the picture it belongs to.
    func normalised(worldPoint point: CGPoint) -> (u: CGFloat, v: CGFloat) {
        let u = worldRect.width > 0 ? (point.x - worldRect.minX) / worldRect.width : 0
        let v = worldRect.height > 0 ? (point.y - worldRect.minY) / worldRect.height : 0
        return (min(max(u, 0), 1), min(max(v, 0), 1))
    }
}

// MARK: - Persistence

@Model
final class ImageEntity {
    @Attribute(.unique) var id: UUID
    var boardID: UUID
    /// The picture this places. Optional so adding it stays a lightweight
    /// migration: a row written before the library existed has nil here and
    /// its own blobs below, and gets a resource minted from them on load.
    var resourceID: UUID?
    /// Legacy, pre-library. Read only by the migration and never written
    /// again. Deliberately not cleared: duplicated bytes for a handful of old
    /// rows is a better trade than any chance of losing them.
    @Attribute(.externalStorage) var originalData: Data
    /// Downscaled copy actually shown. Rebuilt by a resample.
    @Attribute(.externalStorage) var displayData: Data
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var zOrder: Int
    var nativeWidth: Double
    var nativeHeight: Double
    var displayPixelCap: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        boardID: UUID,
        resourceID: UUID? = nil,
        originalData: Data = Data(),
        displayData: Data = Data(),
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        zOrder: Int,
        nativeWidth: Double,
        nativeHeight: Double,
        displayPixelCap: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.boardID = boardID
        self.resourceID = resourceID
        self.originalData = originalData
        self.displayData = displayData
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.zOrder = zOrder
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.displayPixelCap = displayPixelCap
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension ImageEntity {
    /// A placement of a resource. Carries no bytes — they live on the resource.
    convenience init(boardID: UUID, asset: ImageAsset) {
        self.init(
            id: asset.id,
            boardID: boardID,
            resourceID: asset.resourceID,
            x: asset.worldRect.origin.x,
            y: asset.worldRect.origin.y,
            width: asset.worldRect.width,
            height: asset.worldRect.height,
            zOrder: asset.zOrder,
            nativeWidth: asset.nativePixelSize.width,
            nativeHeight: asset.nativePixelSize.height,
            displayPixelCap: asset.displayPixelCap,
            createdAt: asset.createdAt,
            updatedAt: asset.updatedAt
        )
    }

    /// `resource` fills in the picture's own properties. Without it the
    /// placement still reads back, using whatever the row last recorded, so a
    /// resource that has gone does not take the geometry with it.
    func toAsset(resource: ImageResource? = nil) -> ImageAsset {
        ImageAsset(
            id: id,
            resourceID: resourceID ?? resource?.id ?? id,
            worldRect: CGRect(x: x, y: y, width: width, height: height),
            zOrder: zOrder,
            nativePixelSize: resource?.nativePixelSize
                ?? CGSize(width: nativeWidth, height: nativeHeight),
            displayPixelCap: resource?.displayPixelCap ?? displayPixelCap,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Geometry only. The bytes and the display cap belong to the resource.
    func apply(_ asset: ImageAsset) {
        resourceID = asset.resourceID
        x = asset.worldRect.origin.x
        y = asset.worldRect.origin.y
        width = asset.worldRect.width
        height = asset.worldRect.height
        zOrder = asset.zOrder
        updatedAt = asset.updatedAt
    }
}

@Model
final class ImagePinEntity {
    @Attribute(.unique) var id: UUID
    var boardID: UUID
    var imageID: UUID
    var u: Double
    var v: Double

    init(id: UUID = UUID(), boardID: UUID, imageID: UUID, u: Double, v: Double) {
        self.id = id
        self.boardID = boardID
        self.imageID = imageID
        self.u = u
        self.v = v
    }
}

extension ImagePinEntity {
    convenience init(boardID: UUID, pin: ImagePin) {
        self.init(id: pin.id, boardID: boardID, imageID: pin.imageID, u: pin.u, v: pin.v)
    }

    func toPin() -> ImagePin {
        ImagePin(id: id, imageID: imageID, u: u, v: v)
    }
}
