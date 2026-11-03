//
//  ProjectModels.swift
//  Conspire
//

import Foundation
import SwiftData

/// The level above a board.
///
/// A project is what gives "shared" a boundary: its boards can draw on the same
/// resources, and a resource belongs to exactly one project. Boards reference
/// it by a plain `projectID` rather than a SwiftData relationship, matching how
/// fields, links and images are already scoped to a board.
@Model
final class ProjectEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.createdAt = .now
        self.updatedAt = .now
        self.lastOpenedAt = .now
    }
}

struct ProjectSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let lastOpenedAt: Date
    let boardCount: Int
}
