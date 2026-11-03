//
//  ProjectTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Conspire

@MainActor
struct ProjectMigrationTests {

    /// A store as it looked before projects existed: boards with a nil
    /// `projectID`. These tests are the ones standing between the user and a
    /// third data loss, so they work on a real file-backed store.
    private func legacyStore(boardNames: [String]) throws -> TemporaryStore {
        let temp = try TemporaryStore(bootstrap: false)
        let context = temp.service.context!
        for name in boardNames {
            let board = BoardEntity(name: name)
            board.projectID = nil
            context.insert(board)
        }
        try context.save()
        return temp
    }

    @Test func legacyBoardsAreAdoptedByOneProject() throws {
        let temp = try legacyStore(boardNames: ["Alpha", "Beta", "Gamma"])
        temp.service.bootstrap()

        #expect(temp.service.projects.count == 1)
        #expect(temp.service.activeProjectID != nil)
        // Every board kept its name and is now in that project.
        #expect(Set(temp.service.boards.map(\.name)) == ["Alpha", "Beta", "Gamma"])
        #expect(temp.service.projects.first?.boardCount == 3)
    }

    @Test func migrationNeverLosesABoard() throws {
        let temp = try legacyStore(boardNames: ["Alpha", "Beta", "Gamma"])
        let before = try temp.service.context!.fetch(FetchDescriptor<BoardEntity>()).count
        temp.service.bootstrap()
        let after = try temp.service.context!.fetch(FetchDescriptor<BoardEntity>()).count
        #expect(before == 3)
        #expect(after == 3)
    }

    /// Bootstrap runs on every launch, so a second pass must be a no-op rather
    /// than minting another project and moving everything into it.
    @Test func migrationIsIdempotent() throws {
        let temp = try legacyStore(boardNames: ["Alpha", "Beta"])
        temp.service.bootstrap()
        let projectID = temp.service.activeProjectID

        temp.service.bootstrap()

        #expect(temp.service.projects.count == 1)
        #expect(temp.service.activeProjectID == projectID)
        #expect(temp.service.boards.count == 2)
    }

    @Test func aBoardAlreadyInAProjectIsLeftAlone() throws {
        let temp = try TemporaryStore(bootstrap: false)
        let context = temp.service.context!
        let keeper = ProjectEntity(name: "Keeper")
        context.insert(keeper)
        context.insert(BoardEntity(name: "Mine", projectID: keeper.id))
        try context.save()

        temp.service.bootstrap()

        #expect(temp.service.projects.count == 1)
        #expect(temp.service.boards.first?.name == "Mine")
    }

    @Test func anEmptyStoreGetsAProjectAndABoard() throws {
        let temp = try TemporaryStore(bootstrap: false)
        temp.service.bootstrap()

        #expect(temp.service.projects.count == 1)
        #expect(temp.service.boards.count == 1)
        #expect(temp.service.activeBoardID != nil)
    }

    /// The migration touches the user's real store, so it has to hold up across
    /// a genuine reopen rather than only in the session that ran it.
    @Test func adoptionSurvivesAReopen() throws {
        let temp = try legacyStore(boardNames: ["Alpha", "Beta"])
        temp.service.bootstrap()

        let reread = try temp.reopen()
        let boards = try reread.fetch(FetchDescriptor<BoardEntity>())
        let projects = try reread.fetch(FetchDescriptor<ProjectEntity>())

        #expect(projects.count == 1)
        #expect(boards.count == 2)
        #expect(boards.allSatisfy { $0.projectID == projects.first?.id })
    }
}

@MainActor
struct ProjectScopingTests {

    @Test func boardsAreScopedToTheActiveProject() throws {
        let temp = try TemporaryStore()
        let firstProject = temp.service.activeProjectID
        temp.service.createBoard()
        #expect(temp.service.boards.count == 2)

        temp.service.createProject()
        let secondProject = temp.service.activeProjectID
        #expect(secondProject != firstProject)
        // A new project starts with one board of its own, not the other's.
        #expect(temp.service.boards.count == 1)

        temp.service.selectProject(id: firstProject!)
        #expect(temp.service.boards.count == 2)
    }

    @Test func switchingProjectSelectsABoardInIt() throws {
        let temp = try TemporaryStore()
        temp.service.createProject()
        let second = temp.service.activeProjectID!

        let selected = temp.service.activeBoardID
        #expect(selected != nil)
        #expect(temp.service.boards.contains { $0.id == selected })
        #expect(temp.service.activeProjectID == second)
    }

    @Test func renamingAProjectShowsImmediately() throws {
        let temp = try TemporaryStore()
        let id = temp.service.activeProjectID!
        temp.service.renameProject(id: id, name: "  Fieldwork  ")
        #expect(temp.service.activeProjectName == "Fieldwork")
        #expect(temp.service.projects.first?.name == "Fieldwork")
    }

    @Test func anEmptyRenameIsIgnored() throws {
        let temp = try TemporaryStore()
        let id = temp.service.activeProjectID!
        let original = temp.service.activeProjectName
        temp.service.renameProject(id: id, name: "   ")
        #expect(temp.service.activeProjectName == original)
    }

    @Test func theLastProjectCannotBeDeleted() throws {
        let temp = try TemporaryStore()
        let id = temp.service.activeProjectID!
        temp.service.deleteProject(id: id)
        #expect(temp.service.projects.count == 1)
        #expect(temp.service.activeProjectID == id)
    }

    @Test func deletingAProjectTakesItsBoardsAndLeavesTheOthers() throws {
        let temp = try TemporaryStore()
        let keep = temp.service.activeProjectID!
        temp.service.createBoard()

        temp.service.createProject()
        let doomed = temp.service.activeProjectID!
        temp.service.createBoard()
        let doomedBoardIDs = Set(temp.service.boards.map(\.id))

        temp.service.deleteProject(id: doomed)

        #expect(temp.service.projects.count == 1)
        #expect(temp.service.activeProjectID == keep)
        #expect(temp.service.boards.count == 2)
        #expect(temp.service.boards.allSatisfy { !doomedBoardIDs.contains($0.id) })

        let remaining = try temp.service.context!.fetch(FetchDescriptor<BoardEntity>())
        #expect(remaining.allSatisfy { $0.projectID == keep })
    }

    /// Fields, links, images and pins hang off a `boardID` rather than a
    /// SwiftData relationship, so nothing cascades to them. Before this they
    /// accumulated invisibly whenever a board went.
    @Test func deletingABoardTakesWhatWasOnIt() throws {
        let temp = try TemporaryStore()
        let boardID = temp.service.activeBoardID!
        temp.service.createBoard()

        temp.store.activeBoardID = boardID
        temp.store.placementMode = .field
        temp.store.fieldDraftStroke = (0..<48).map { i in
            let a = CGFloat(i) / 48 * .pi * 2
            return CGPoint(x: 200 + cos(a) * 60, y: 200 + sin(a) * 60)
        }
        temp.store.endFieldStroke()
        #expect(try temp.service.context!.fetch(FetchDescriptor<FieldEntity>()).count == 1)

        temp.service.deleteBoard(id: boardID)

        #expect(try temp.service.context!.fetch(FetchDescriptor<FieldEntity>()).isEmpty)
    }
}
