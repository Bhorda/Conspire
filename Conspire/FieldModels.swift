//
//  FieldModels.swift
//  Conspire
//

import CoreGraphics
import Foundation
import SwiftData

/// A zone drawn on the canvas. Notes sitting inside one carry it as an
/// attribute; fields overlap freely, so a note can belong to several at once.
struct Field: Identifiable, Equatable, Sendable {
    var id: UUID
    var ring: FieldRing
    var colourIndex: Int
    var label: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        ring: FieldRing,
        colourIndex: Int = 0,
        label: String = "Field",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ring = ring
        self.colourIndex = colourIndex
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// How dragging an outline reshapes it.
enum FieldReshapeMode: String, CaseIterable, Sendable {
    /// Press anywhere on the outline and drag; nearby outline follows with a soft falloff.
    case clay
    /// Drag one of the evenly spaced control handles.
    case handles

    var label: String {
        switch self {
        case .clay: return "Clay"
        case .handles: return "Handles"
        }
    }
}

// MARK: - Persistence

@Model
final class FieldEntity {
    @Attribute(.unique) var id: UUID
    var boardID: UUID
    /// JSON-encoded `[[Double]]` of ring points (x, y pairs).
    var ringBlob: Data
    var colorIndex: Int
    var label: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        boardID: UUID,
        ringBlob: Data,
        colorIndex: Int,
        label: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.boardID = boardID
        self.ringBlob = ringBlob
        self.colorIndex = colorIndex
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension FieldEntity {
    convenience init(boardID: UUID, field: Field) {
        self.init(
            id: field.id,
            boardID: boardID,
            ringBlob: FieldEntity.encodeRing(field.ring),
            colorIndex: field.colourIndex,
            label: field.label,
            createdAt: field.createdAt,
            updatedAt: field.updatedAt
        )
    }

    func toField() -> Field {
        Field(
            id: id,
            ring: FieldEntity.decodeRing(ringBlob),
            colourIndex: colorIndex,
            label: label,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func encodeRing(_ ring: FieldRing) -> Data {
        let pairs = ring.map { [Double($0.x), Double($0.y)] }
        return (try? JSONEncoder().encode(pairs)) ?? Data()
    }

    static func decodeRing(_ data: Data) -> FieldRing {
        guard let pairs = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
    }
}
