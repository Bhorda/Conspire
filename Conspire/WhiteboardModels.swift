//
//  WhiteboardModels.swift
//  Conspire
//

import CoreGraphics
import Foundation

struct NoteRender: Identifiable, Equatable {
    let id: UUID
    /// Already resolved: for a library note this is the resource's text, not
    /// the row's own copy.
    let text: String
    let colour: Int
    /// Set when the note came from the text library.
    var textResourceID: UUID? = nil
}

struct NoteGroupRender: Identifiable, Equatable {
    let id: UUID
    let anchor: CGPoint
    let zOrder: Int
    let noteIDs: [UUID]
}

struct StickyNote: Identifiable, Equatable, Sendable {
    typealias ID = UUID

    var id: ID
    var text: String
    var colour: Int

    init(id: ID = UUID(), text: String = "", colour: Int = 0) {
        self.id = id
        self.text = text
        self.colour = colour
    }
}

/// Legacy name kept for domain docs; board uses `NoteGroup` in `GroupLogic.swift`.
struct NoteStack: Identifiable, Equatable, Sendable {
    typealias ID = UUID

    var id: ID
    var noteIDs: [StickyNote.ID]
    var origin: CGPoint

    init(id: ID = UUID(), noteIDs: [StickyNote.ID], origin: CGPoint) {
        self.id = id
        self.noteIDs = noteIDs
        self.origin = origin
    }

    var topNoteID: StickyNote.ID? { noteIDs.last }
}
