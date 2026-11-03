//
//  WhiteboardModels.swift
//  Conspire
//

import CoreGraphics
import Foundation

/// The faint symbol a note can carry behind its text.
///
/// Was `@State` on the card, which meant it was never saved and never survived
/// a scroll that recycled the view — a control that forgets is worse than no
/// control, so now it is on the note.
enum NoteStamp {
    static let symbols: [String] = [
        "lightbulb", "exclamationmark", "questionmark", "xmark", "checkmark",
        "text.bubble", "link", "sparkles", "flame", "snowflake",
        "ladybug", "magnifyingglass", "circle", "square", "triangleshape",
    ]

    private static let names: [String: String] = [
        "lightbulb": "Idea",
        "exclamationmark": "Important",
        "questionmark": "Question",
        "xmark": "Rejected",
        "checkmark": "Done",
        "text.bubble": "Comment",
        "link": "Related",
        "sparkles": "Insight",
        "flame": "Hot",
        "snowflake": "Parked",
        "ladybug": "Problem",
        "magnifyingglass": "Look closer",
        "circle": "Circle",
        "square": "Square",
        "triangleshape": "Triangle",
    ]

    static func name(for symbol: String) -> String {
        names[symbol] ?? symbol
    }
}

struct NoteRender: Identifiable, Equatable {
    let id: UUID
    /// Already resolved: for a library note this is the resource's text, not
    /// the row's own copy.
    let text: String
    let colour: Int
    /// Set when the note came from the text library.
    var textResourceID: UUID? = nil
    /// SF Symbol drawn faintly behind the text, if any.
    var stamp: String? = nil
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
