import Foundation
import SwiftData

@Model
final class LinkEntity {
    @Attribute(.unique) var id: UUID
    var boardID: UUID
    /// Legacy endpoint kind: true = note, false = stack. Kept because changing
    /// its type would need a migration stage; `fromKind` supersedes it.
    var fromIsNote: Bool
    var fromID: UUID
    var toIsNote: Bool
    var toID: UUID
    /// Endpoint kind as `NodeID.Kind`. Optional so adding it stays a
    /// lightweight migration; nil means a row written before pins existed,
    /// which is read from the Bool instead.
    var fromKind: Int?
    var toKind: Int?
    var colorIndex: Int
    var label: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), boardID: UUID, fromIsNote: Bool, fromID: UUID, toIsNote: Bool, toID: UUID, fromKind: Int? = nil, toKind: Int? = nil, colorIndex: Int, label: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.boardID = boardID
        self.fromIsNote = fromIsNote
        self.fromID = fromID
        self.toIsNote = toIsNote
        self.toID = toID
        self.fromKind = fromKind
        self.toKind = toKind
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
        self.init(
            id: link.id.rawValue,
            boardID: boardID,
            fromIsNote: fromIsNote,
            fromID: fromID,
            toIsNote: toIsNote,
            toID: toID,
            fromKind: link.from.kind.rawValue,
            toKind: link.to.kind.rawValue,
            colorIndex: link.colorIndex,
            label: link.label,
            createdAt: link.createdAt,
            updatedAt: link.updatedAt
        )
    }

    func toLink() -> Link {
        Link(
            id: LinkID(id),
            from: NodeID(kind: fromKind, legacyIsNote: fromIsNote, id: fromID),
            to: NodeID(kind: toKind, legacyIsNote: toIsNote, id: toID),
            colorIndex: colorIndex,
            label: label,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension NodeID {
    enum Kind: Int {
        case note = 0
        case stack = 1
        case pin = 2
    }

    var kind: Kind {
        switch self {
        case .note: return .note
        case .stack: return .stack
        case .pin: return .pin
        }
    }

    /// Reads the stored kind, falling back to the legacy Bool for rows written
    /// before pins existed.
    init(kind: Int?, legacyIsNote: Bool, id: UUID) {
        switch kind.flatMap(Kind.init(rawValue:)) ?? (legacyIsNote ? .note : .stack) {
        case .note: self = .note(id)
        case .stack: self = .stack(id)
        case .pin: self = .pin(id)
        }
    }

    /// Legacy pair, still written so a downgrade reads something sensible.
    /// A pin has no legacy equivalent and records as "not a note".
    func asRaw() -> (Bool, UUID) {
        switch self {
        case .note(let nid): return (true, nid)
        case .stack(let gid): return (false, gid)
        case .pin(let pid): return (false, pid)
        }
    }
}
