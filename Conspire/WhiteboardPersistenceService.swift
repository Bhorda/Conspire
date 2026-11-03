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
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var activeProjectID: UUID?
    @Published private(set) var activeProjectName: String = ""
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
        refreshProjects()
    }

    func flushPendingSaves() {
        flushViewport()
        saveTask?.cancel()
        saveTask = nil
        try? context?.save()
    }

    func bootstrap() {
        guard let context else { return }
        adoptProjectlessBoards()

        if activeProjectID == nil, let project = fetchMostRecentProject() {
            setActiveProject(project)
        }
        refreshBoards()

        if boards.isEmpty, let projectID = activeProjectID {
            context.insert(BoardEntity(name: "Untitled", projectID: projectID))
            try? context.save()
            refreshBoards()
        }
        if let board = fetchMostRecentBoard() {
            selectBoard(id: board.id)
        }
    }

    // MARK: - Projects

    /// Boards written before projects existed have no project. They are all
    /// adopted by one, created if there is none.
    ///
    /// Idempotent and keyed on `projectID == nil`, so running it again does
    /// nothing, and it only ever *adds* a reference — no board is moved,
    /// renamed or removed.
    private func adoptProjectlessBoards() {
        guard let context else { return }
        let orphans = (try? context.fetch(
            FetchDescriptor<BoardEntity>(predicate: #Predicate { $0.projectID == nil })
        )) ?? []

        let project = fetchMostRecentProject() ?? insertProject(named: "My Project")
        setActiveProject(project)
        guard !orphans.isEmpty else {
            refreshProjects()
            return
        }
        for board in orphans {
            board.projectID = project.id
        }
        try? context.save()
        refreshProjects()
    }

    private func insertProject(named name: String) -> ProjectEntity {
        let project = ProjectEntity(name: name)
        context?.insert(project)
        try? context?.save()
        return project
    }

    private func setActiveProject(_ project: ProjectEntity) {
        activeProjectID = project.id
        activeProjectName = project.name
    }

    func createProject() {
        guard let context else { return }
        let project = insertProject(named: nextUntitledName(among: projects.map(\.name), stem: "Project"))
        setActiveProject(project)
        // A project with no boards has nothing to show, so it starts with one.
        context.insert(BoardEntity(name: "Untitled", projectID: project.id))
        try? context.save()
        refreshProjects()
        refreshBoards()
        if let board = fetchMostRecentBoard() { selectBoard(id: board.id) }
    }

    func selectProject(id: UUID) {
        guard id != activeProjectID, let project = fetchProject(id: id) else { return }
        flushPendingSaves()
        project.lastOpenedAt = .now
        project.updatedAt = .now
        setActiveProject(project)
        invalidateBoardCache()
        activeBoardID = nil
        try? context?.save()
        refreshProjects()
        refreshBoards()
        if let board = fetchMostRecentBoard() { selectBoard(id: board.id) }
    }

    func renameProject(id: UUID, name: String) {
        guard let project = fetchProject(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.name = trimmed.isEmpty ? project.name : String(trimmed.prefix(64))
        project.updatedAt = .now
        try? context?.save()
        if activeProjectID == id { activeProjectName = project.name }
        refreshProjects()
    }

    /// Boards in a project go with it, and so does everything scoped to those
    /// boards. Refuses to remove the last project.
    func deleteProject(id: UUID) {
        guard let context, projects.count > 1, let project = fetchProject(id: id) else { return }
        let wasActive = activeProjectID == id
        for board in boards(inProject: id) {
            purgeBoardScopedEntities(boardID: board.id)
            context.delete(board)
        }
        context.delete(project)
        try? context.save()
        invalidateBoardCache()
        refreshProjects()

        if wasActive {
            activeProjectID = nil
            activeProjectName = ""
            activeBoardID = nil
            if let next = fetchMostRecentProject() { setActiveProject(next) }
            refreshBoards()
            if let board = fetchMostRecentBoard() { selectBoard(id: board.id) }
        }
    }

    func projectCount() -> Int { projects.count }

    private func fetchProject(id: UUID) -> ProjectEntity? {
        guard let context else { return nil }
        let predicate = #Predicate<ProjectEntity> { $0.id == id }
        return try? context.fetch(FetchDescriptor<ProjectEntity>(predicate: predicate)).first
    }

    private func fetchMostRecentProject() -> ProjectEntity? {
        guard let context else { return nil }
        return try? context.fetch(
            FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        ).first
    }

    private func boards(inProject projectID: UUID) -> [BoardEntity] {
        guard let context else { return [] }
        let predicate = #Predicate<BoardEntity> { $0.projectID == projectID }
        return (try? context.fetch(FetchDescriptor<BoardEntity>(predicate: predicate))) ?? []
    }

    private func refreshProjects() {
        guard let context else { return }
        let list = (try? context.fetch(
            FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        )) ?? []
        projects = list.map { project in
            ProjectSummary(
                id: project.id,
                name: project.name,
                lastOpenedAt: project.lastOpenedAt,
                boardCount: boards(inProject: project.id).count
            )
        }
    }

    /// Fields, links, images and pins are scoped by `boardID` rather than by a
    /// SwiftData relationship, so deleting a board does not cascade to them.
    /// Without this they accumulate forever, invisible.
    private func purgeBoardScopedEntities(boardID: UUID) {
        guard let context else { return }
        let target = boardID
        for entity in (try? context.fetch(
            FetchDescriptor<FieldEntity>(predicate: #Predicate { $0.boardID == target })
        )) ?? [] { context.delete(entity) }
        for entity in (try? context.fetch(
            FetchDescriptor<LinkEntity>(predicate: #Predicate { $0.boardID == target })
        )) ?? [] { context.delete(entity) }
        for entity in (try? context.fetch(
            FetchDescriptor<ImageEntity>(predicate: #Predicate { $0.boardID == target })
        )) ?? [] { context.delete(entity) }
        for entity in (try? context.fetch(
            FetchDescriptor<ImagePinEntity>(predicate: #Predicate { $0.boardID == target })
        )) ?? [] { context.delete(entity) }
    }

    func createBoard() {
        guard let context, let projectID = activeProjectID else { return }
        let board = BoardEntity(name: nextUntitledName(), projectID: projectID)
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
            purgeBoardScopedEntities(boardID: board.id)
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
    func createNote(
        atWorldCenter worldCenter: CGPoint,
        colour: Int,
        textResourceID: UUID? = nil
    ) -> UUID? {
        guard let context, let board = activeBoard() else { return nil }
        let note = NoteEntity(
            text: "", colour: colour, textResourceID: textResourceID, board: board
        )
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
            let clone = NoteEntity(
                text: src.text,
                colour: src.colour,
                textResourceID: src.textResourceID,
                board: board
            )
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
        if let resourceID = note.textResourceID, let resource = textResourceEntity(id: resourceID) {
            // A library note shows its resource's words, so this is the edit
            // that reaches every board showing it. The row's own copy is kept
            // in step as the last words it displayed.
            resource.text = text
            resource.updatedAt = .now
        }
        note.text = text
        board.updatedAt = .now
        scheduleSave()
        refreshActiveBoardData()
    }

    func textResourceEntity(id: UUID) -> TextResourceEntity? {
        guard let context else { return nil }
        let target = id
        let predicate = #Predicate<TextResourceEntity> { $0.id == target }
        return try? context.fetch(FetchDescriptor<TextResourceEntity>(predicate: predicate)).first
    }

    /// Rebuilds the open board's render data. Needed when something off-board
    /// changes what it shows — a text resource being edited or removed.
    func refreshActiveBoard() {
        refreshActiveBoardData()
    }

    /// A library note's words come from its resource, not from its own row.
    private func resolvedTexts(for notes: [NoteEntity]) -> [UUID: String] {
        guard let context else { return [:] }
        let ids = Array(Set(notes.compactMap(\.textResourceID)))
        guard !ids.isEmpty else { return [:] }
        let rows = (try? context.fetch(FetchDescriptor<TextResourceEntity>(
            predicate: #Predicate { ids.contains($0.id) }
        ))) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.text) })
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
        guard let context, let projectID = activeProjectID else { return nil }
        var descriptor = FetchDescriptor<BoardEntity>(
            predicate: #Predicate { $0.projectID == projectID },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
        guard let context, let projectID = activeProjectID else {
            boards = []
            return
        }
        let list = (try? context.fetch(FetchDescriptor<BoardEntity>(
            predicate: #Predicate { $0.projectID == projectID },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        ))) ?? []
        boards = list.map {
            BoardSummary(id: $0.id, name: $0.name, lastOpenedAt: $0.lastOpenedAt, noteCount: $0.notes.count)
        }
    }

    private func refreshActiveBoardData() {
        guard let board = activeBoard() else { return }
        activeCanvasPan = CGSize(width: board.canvasPanX, height: board.canvasPanY)
        activeCanvasScale = CGFloat(board.canvasScale)
        let resolved = resolvedTexts(for: board.notes)
        activeNotesByID = Dictionary(
            uniqueKeysWithValues: board.notes.map { note in
                (
                    note.id,
                    NoteRender(
                        id: note.id,
                        text: note.textResourceID.flatMap { resolved[$0] } ?? note.text,
                        colour: note.colour,
                        textResourceID: note.textResourceID
                    )
                )
            }
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
        nextUntitledName(among: boards.map(\.name), stem: "Untitled")
    }

    private func nextUntitledName(among existing: [String], stem: String) -> String {
        let names = Set(existing)
        if !names.contains(stem) { return stem }
        var i = 2
        while names.contains("\(stem) \(i)") { i += 1 }
        return "\(stem) \(i)"
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

