//
//  WhiteboardPersistenceModels.swift
//  Conspire
//

import Foundation
import SwiftData

@Model
final class BoardEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date
    var canvasPanX: Double
    var canvasPanY: Double
    var canvasScale: Double
    /// Optional so adding it stays a lightweight migration. A board written
    /// before projects existed has nil here and is adopted by the first
    /// project on load.
    var projectID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \NoteEntity.board) var notes: [NoteEntity]
    @Relationship(deleteRule: .cascade, inverse: \NoteGroupEntity.board) var groups: [NoteGroupEntity]

    init(id: UUID = UUID(), name: String, projectID: UUID? = nil) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.createdAt = .now
        self.updatedAt = .now
        self.lastOpenedAt = .now
        self.canvasPanX = 0
        self.canvasPanY = 0
        self.canvasScale = 1
        self.notes = []
        self.groups = []
    }
}

@Model
final class NoteEntity {
    @Attribute(.unique) var id: UUID
    /// The note's own words. Ignored while `textResourceID` is set, where the
    /// resource is the one source of truth — kept as the last words it showed,
    /// so losing the resource does not blank the note.
    var text: String
    var colour: Int
    /// Set when this note came from the text library. Optional so adding it
    /// stays a lightweight migration.
    var textResourceID: UUID?
    /// SF Symbol drawn faintly behind the text. nil means none.
    var stamp: String?
    var board: BoardEntity?

    init(
        id: UUID = UUID(),
        text: String = "",
        colour: Int = 0,
        textResourceID: UUID? = nil,
        stamp: String? = nil,
        board: BoardEntity? = nil
    ) {
        self.id = id
        self.text = text
        self.colour = colour
        self.textResourceID = textResourceID
        self.stamp = stamp
        self.board = board
    }
}

@Model
final class NoteGroupEntity {
    @Attribute(.unique) var id: UUID
    /// World-space center of the bottom (index 0) note.
    var anchorX: Double
    var anchorY: Double
    var zOrder: Int
    /// JSON-encoded `[UUID]` (bottom → top).
    var noteIDsBlob: Data
    var board: BoardEntity?

    init(
        id: UUID = UUID(),
        anchorX: Double,
        anchorY: Double,
        zOrder: Int,
        noteIDsBlob: Data,
        board: BoardEntity? = nil
    ) {
        self.id = id
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.zOrder = zOrder
        self.noteIDsBlob = noteIDsBlob
        self.board = board
    }

    static func encodeNoteIDs(_ ids: [UUID]) -> Data {
        (try? JSONEncoder().encode(ids)) ?? Data()
    }

    static func decodeNoteIDs(_ data: Data) -> [UUID] {
        (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
    }
}

struct BoardSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let lastOpenedAt: Date
    let noteCount: Int
}
