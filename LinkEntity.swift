import Foundation
import SwiftData

@Model
final class LinkEntity {
    @Attribute(.unique) var id: UUID
    var boardID: UUID
    var fromIsNote: Bool
    var fromID: UUID
    var toIsNote: Bool
    var toID: UUID
    var colorIndex: Int
    var label: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), boardID: UUID, fromIsNote: Bool, fromID: UUID, toIsNote: Bool, toID: UUID, colorIndex: Int, label: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.boardID = boardID
        self.fromIsNote = fromIsNote
        self.fromID = fromID
        self.toIsNote = toIsNote
        self.toID = toID
        self.colorIndex = colorIndex
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension LinkEntity {
    convenience init(boardID: UUID, link: Link) {
        let (fromIsNote, fromID) = link.from.asRaw()
        let (toIsNote, toID) = link.to.asRaw()
        self.init(id: link.id.rawValue, boardID: boardID, fromIsNote: fromIsNote, fromID: fromID, toIsNote: toIsNote, toID: toID, colorIndex: link.colorIndex, label: link.label, createdAt: link.createdAt, updatedAt: link.updatedAt)
    }

    func toLink() -> Link {
        let from: NodeID = fromIsNote ? .note(fromID) : .stack(fromID)
        let to: NodeID = toIsNote ? .note(toID) : .stack(toID)
        var link = Link(id: LinkID(id), from: from, to: to, colorIndex: colorIndex, label: label, createdAt: createdAt, updatedAt: updatedAt)
        return link
    }
}

extension NodeID {
    func asRaw() -> (Bool, UUID) {
        switch self {
        case .note(let nid): return (true, nid)
        case .stack(let gid): return (false, gid)
        }
    }
}
