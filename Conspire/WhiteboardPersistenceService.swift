//
//  WhiteboardPersistenceService.swift
//  Conspire
//

import Combine
import CoreGraphics
import Foundation
import SwiftData

@MainActor
final class WhiteboardPersistenceService: ObservableObject {
    @Published private(set) var boards: [BoardSummary] = []
    @Published private(set) var activeBoardID: UUID?
    @Published private(set) var activeBoardName: String = ""
    @Published private(set) var activeCanvasPan: CGSize = .zero
    @Published private(set) var activeCanvasScale: CGFloat = 1
    @Published private(set) var activeNotesByID: [UUID: NoteRender] = [:]
    @Published private(set) var activeGroups: [NoteGroupRender] = []

    var context: ModelContext?
    private var saveTask: Task<Void, Never>?
    /// Pan/scale arrive once per scroll event. Writing them through to SwiftData
    /// each time cost a fetch and a published change per event, so they are held
    /// here and flushed once the gesture settles.
    private var pendingCanvasPan: CGSize?
    private var pendingCanvasScale: CGFloat?
    private var viewportSaveTask: Task<Void, Never>?
    private var cachedBoard: BoardEntity?
    private var cachedBoardID: UUID?

    func configure(context: ModelContext) {
        self.context = context
        refreshBoards()
    }

    func flushPendingSaves() {
        flushViewport()
        saveTask?.cancel()
        saveTask = nil
        try? context?.save()
    }

    func bootstrap() {
        guard let context else { return }
        if boards.isEmpty {
            context.insert(BoardEntity(name: "Untitled"))
            try? context.save()
            refreshBoards()
        }
        if let board = fetchMostRecentBoard() {
            selectBoard(id: board.id)
        }
    }

    func createBoard() {
        guard let context else { return }
        let board = BoardEntity(name: nextUntitledName())
        context.insert(board)
        try? context.save()
        refreshBoards()
        selectBoard(id: board.id)
    }

    func renameBoard(id: UUID, name: String) {
        guard let board = fetchBoard(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        board.name = trimmed.isEmpty ? board.name : String(trimmed.prefix(64))
        board.updatedAt = .now
        try? context?.save()
        refreshBoards()
        if activeBoardID == id { activeBoardName = board.name }
    }

    func deleteBoard(id: UUID) {
        guard let context else { return }
        guard boards.count > 1 else { return }
        let wasActive = activeBoardID == id
        if let board = fetchBoard(id: id) {
            context.delete(board)
            try? context.save()
        }
        invalidateBoardCache()
        refreshBoards()
        if wasActive, let next = fetchMostRecentBoard() {
            selectBoard(id: next.id)
        }
    }

    func selectBoard(id: UUID) {
        guard let board = fetchBoard(id: id) else { return }
        board.lastOpenedAt = .now
        board.updatedAt = .now
        flushPendingSaves()
        try? context?.save()
        activeBoardID = board.id
        activeBoardName = board.name
        refreshBoards()
        refreshActiveBoardData()
    }

    func boardCount() -> Int { boards.count }

    /// Creates a single note and a one-note group whose anchor is the world-space center of that note.
    func createNote(atWorldCenter worldCenter: CGPoint, colour: Int) -> UUID? {
        guard let context, let board = activeBoard() else { return nil }
        let note = NoteEntity(text: "", colour: colour, board: board)
        let noteID = note.id
        context.insert(note)
        board.notes.append(note)

        let maxZ = board.groups.map(\.zOrder).max() ?? -1
        let blob = NoteGroupEntity.encodeNoteIDs([noteID])
        let group = NoteGroupEntity(
            anchorX: worldCenter.x,
            anchorY: worldCenter.y,
            zOrder: maxZ + 1,
            noteIDsBlob: blob,
            board: board
        )
        context.insert(group)
        board.groups.append(group)

        board.updatedAt = .now
        scheduleSave()
        refreshActiveBoardData()
        return noteID
    }

    /// Appends a new empty note to the top of an existing board group (same anchor; stack grows upward).
    func appendNoteOnTopOfGroup(groupID: UUID, colour: Int) -> UUID? {
        guard let context, let board = activeBoard() else { return nil }
        guard let groupEnt = board.groups.first(where: { $0.id == groupID }) else { return nil }

        let note = NoteEntity(text: "", colour: colour, board: board)
        let noteID = note.id
        context.insert(note)
        board.notes.append(note)

        var ids = NoteGroupEntity.decodeNoteIDs(groupEnt.noteIDsBlob)
        ids.append(noteID)
        groupEnt.noteIDsBlob = NoteGroupEntity.encodeNoteIDs(ids)

        board.updatedAt = .now
        scheduleSave()
        refreshActiveBoardData()
        return noteID
    }

    /// Clones each source note onto the active board (same text/colour), preserving order. Returns new IDs (may be shorter if a source ID was missing).
    func duplicateNotes(sourceIDs: [UUID]) -> [UUID] {
        guard let context, let board = activeBoard() else { return [] }
        var newIDs: [UUID] = []
        newIDs.reserveCapacity(sourceIDs.count)
        let byID = Dictionary(uniqueKeysWithValues: board.notes.map { ($0.id, $0) })
        for srcID in sourceIDs {
            guard let src = byID[srcID] else { continue }
            let clone = NoteEntity(text: src.text, colour: src.colour, board: board)
            context.insert(clone)
            board.notes.append(clone)
            newIDs.append(clone.id)
        }
        board.updatedAt = .now
        scheduleSave()
        refreshActiveBoardData()
        return newIDs
    }

    func updateNoteText(noteID: UUID, text: String) {
        guard let board = activeBoard(), let note = board.notes.first(where: { $0.id == noteID }) else { return }
        note.text = text
        board.updatedAt = .now
        scheduleSave()
        refreshActiveBoardData()
    }

    func setCanvasPan(_ pan: CGSize) {
        pendingCanvasPan = pan
        scheduleViewportFlush()
    }

    func setCanvasScale(_ scale: CGFloat) {
        pendingCanvasScale = scale
        scheduleViewportFlush()
    }

    private func scheduleViewportFlush(delayNs: UInt64 = 400_000_000) {
        viewportSaveTask?.cancel()
        viewportSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            self.flushViewport()
        }
    }

    private func flushViewport() {
        viewportSaveTask?.cancel()
        viewportSaveTask = nil
        guard pendingCanvasPan != nil || pendingCanvasScale != nil else { return }
        guard let board = activeBoard() else { return }
        if let pan = pendingCanvasPan {
            board.canvasPanX = pan.width
            board.canvasPanY = pan.height
            activeCanvasPan = pan
            pendingCanvasPan = nil
        }
        if let scale = pendingCanvasScale {
            board.canvasScale = scale
            activeCanvasScale = scale
            pendingCanvasScale = nil
        }
        board.updatedAt = .now
        try? context?.save()
    }

    func note(for id: UUID) -> NoteRender? { activeNotesByID[id] }

    /// Replaces all groups on the active board with `groups`. Notes are never deleted here (carried notes may be off-board).
    func replaceBoardGroups(_ groups: [NoteGroup]) {
        guard let context, let board = activeBoard() else { return }

        let toDelete = Array(board.groups)
        for g in toDelete {
            context.delete(g)
        }

        for ng in groups {
            let blob = NoteGroupEntity.encodeNoteIDs(ng.noteIDs)
            let ent = NoteGroupEntity(
                id: ng.id,
                anchorX: ng.anchor.x,
                anchorY: ng.anchor.y,
                zOrder: ng.zOrder,
                noteIDsBlob: blob,
                board: board
            )
            context.insert(ent)
            board.groups.append(ent)
        }

        board.updatedAt = .now
        flushPendingSaves()
        try? context.save()
        refreshActiveBoardData()
    }

    func deleteNotes(_ ids: Set<UUID>) {
        guard let context, let board = activeBoard() else { return }
        for note in board.notes where ids.contains(note.id) {
            context.delete(note)
        }
        for group in board.groups {
            let kept = NoteGroupEntity.decodeNoteIDs(group.noteIDsBlob).filter { !ids.contains($0) }
            if kept.isEmpty {
                context.delete(group)
            } else {
                group.noteIDsBlob = NoteGroupEntity.encodeNoteIDs(kept)
            }
        }
        board.groups.removeAll { $0.noteIDsBlob.isEmpty || NoteGroupEntity.decodeNoteIDs($0.noteIDsBlob).isEmpty }
        board.updatedAt = .now
        flushPendingSaves()
        try? context.save()
        refreshActiveBoardData()
    }

    private func fetchBoard(id: UUID) -> BoardEntity? {
        guard let context else { return nil }
        let predicate = #Predicate<BoardEntity> { $0.id == id }
        return try? context.fetch(FetchDescriptor<BoardEntity>(predicate: predicate)).first
    }

    private func fetchMostRecentBoard() -> BoardEntity? {
        guard let context else { return nil }
        return try? context.fetch(FetchDescriptor<BoardEntity>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])).first
    }

    private func activeBoard() -> BoardEntity? {
        guard let id = activeBoardID else { return nil }
        if let cachedBoard, cachedBoardID == id, !cachedBoard.isDeleted {
            return cachedBoard
        }
        let board = fetchBoard(id: id)
        cachedBoard = board
        cachedBoardID = board == nil ? nil : id
        return board
    }

    private func invalidateBoardCache() {
        cachedBoard = nil
        cachedBoardID = nil
    }

    private func refreshBoards() {
        guard let context else { return }
        let list = (try? context.fetch(FetchDescriptor<BoardEntity>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]))) ?? []
        boards = list.map {
            BoardSummary(id: $0.id, name: $0.name, lastOpenedAt: $0.lastOpenedAt, noteCount: $0.notes.count)
        }
    }

    private func refreshActiveBoardData() {
        guard let board = activeBoard() else { return }
        activeCanvasPan = CGSize(width: board.canvasPanX, height: board.canvasPanY)
        activeCanvasScale = CGFloat(board.canvasScale)
        activeNotesByID = Dictionary(
            uniqueKeysWithValues: board.notes.map { ($0.id, NoteRender(id: $0.id, text: $0.text, colour: $0.colour)) }
        )
        activeGroups = board.groups
            .sorted {
                if $0.zOrder != $1.zOrder { return $0.zOrder < $1.zOrder }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { g in
                NoteGroupRender(
                    id: g.id,
                    anchor: CGPoint(x: g.anchorX, y: g.anchorY),
                    zOrder: g.zOrder,
                    noteIDs: NoteGroupEntity.decodeNoteIDs(g.noteIDsBlob)
                )
            }
        refreshBoards()
    }

    private func nextUntitledName() -> String {
        let names = Set(boards.map(\.name))
        if !names.contains("Untitled") { return "Untitled" }
        var i = 2
        while names.contains("Untitled \(i)") { i += 1 }
        return "Untitled \(i)"
    }

    private func scheduleSave(delayNs: UInt64 = 300_000_000) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            try? context?.save()
            saveTask = nil
        }
    }
}

