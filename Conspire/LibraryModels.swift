//
//  LibraryModels.swift
//  Conspire
//

import CoreGraphics
import Foundation
import SwiftData

/// A picture belonging to a project.
///
/// The split that makes sharing possible: **a resource owns the content, a
/// placement owns the position.** `ImageEntity` is now a placement — a rect on
/// one board — and this holds the bytes, once, however many boards show it.
/// So the same photo on three boards is one set of blobs and one decode, and
/// "where else is this used?" is a query rather than a guess.
@Model
final class ImageResourceEntity {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var name: String
    /// What was imported, untouched, so a resample always has something better
    /// to go back to than what is currently on screen.
    @Attribute(.externalStorage) var originalData: Data
    /// Downscaled copy actually drawn on the canvas.
    @Attribute(.externalStorage) var displayData: Data
    /// Small copy for the library grid. Stored rather than re-derived so the
    /// grid keeps the one-decode-per-image rule: a 50-image library costs a few
    /// milliseconds instead of re-decoding fifty full display assets.
    @Attribute(.externalStorage) var thumbnailData: Data
    var nativeWidth: Double
    var nativeHeight: Double
    var displayPixelCap: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        originalData: Data,
        displayData: Data,
        thumbnailData: Data,
        nativeWidth: Double,
        nativeHeight: Double,
        displayPixelCap: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.originalData = originalData
        self.displayData = displayData
        self.thumbnailData = thumbnailData
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.displayPixelCap = displayPixelCap
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var nativePixelSize: CGSize {
        CGSize(width: nativeWidth, height: nativeHeight)
    }
}

/// A piece of reusable text belonging to a project — a code from a codebook, a
/// quote. A sticky note made from one shows *its* text, so fixing the wording
/// here fixes it on every board.
@Model
final class TextResourceEntity {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var text: String
    /// Unused by the UI for now. A codebook wants grouping and "this code is
    /// always blue", and adding a column later is the expensive part.
    var category: String?
    var colour: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        projectID: UUID,
        text: String,
        category: String? = nil,
        colour: Int? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.text = text
        self.category = category
        self.colour = colour
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Values

/// A library image, without its bytes. The grid needs the thumbnail and the
/// name; it has no business holding a 1024px display asset.
struct ImageResource: Identifiable, Equatable {
    let id: UUID
    var name: String
    var nativePixelSize: CGSize
    var displayPixelCap: Int
    var createdAt: Date

    var nativeLongEdge: CGFloat { max(nativePixelSize.width, nativePixelSize.height) }
}

struct TextResource: Identifiable, Equatable {
    let id: UUID
    var text: String
    var category: String?
    var colour: Int?
    var createdAt: Date
}

/// One appearance of a resource: which board, and where on it.
///
/// `worldPoint` is what Locate needs — the centre of the placement, so the
/// board can be brought to it.
struct ResourceUse: Identifiable, Equatable {
    let id: UUID
    let boardID: UUID
    let boardName: String
    let worldPoint: CGPoint
    /// True when this use is on the board currently open.
    var isOnActiveBoard: Bool
}

extension ImageResourceEntity {
    func toResource() -> ImageResource {
        ImageResource(
            id: id,
            name: name,
            nativePixelSize: nativePixelSize,
            displayPixelCap: displayPixelCap,
            createdAt: createdAt
        )
    }
}

extension TextResourceEntity {
    func toResource() -> TextResource {
        TextResource(id: id, text: text, category: category, colour: colour, createdAt: createdAt)
    }
}
