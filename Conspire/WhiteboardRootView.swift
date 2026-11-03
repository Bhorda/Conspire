//
//  WhiteboardRootView.swift
//  Conspire
//

import SwiftUI
import SwiftData

struct WhiteboardRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @StateObject private var store = WhiteboardStore()
    @StateObject private var persistence = WhiteboardPersistenceService()
    @AppStorage("isSidebarCollapsed") private var isSidebarCollapsed: Bool = true
    @AppStorage("isLibraryCollapsed") private var isLibraryCollapsed: Bool = true
    @AppStorage("libraryTab") private var libraryTab: LibraryTab = .images
    @AppStorage("showDebugHUD") private var showDebugHUD: Bool = false
    @State private var didBootstrap = false
    @State private var renameBoardID: UUID?
    @State private var renameDraft: String = ""
    @State private var pendingDeleteBoardID: UUID?
    @State private var pendingDeleteBoardName: String = ""
    @State private var isRenamingProject = false
    @State private var projectRenameDraft: String = ""
    @State private var isConfirmingProjectDelete = false
    
    @State private var shiftHeld = false
    @State private var commandHeld = false
    @State private var optionHeld = false
    
    @Namespace private var keyboardHints
    
    private var hintPrimaryLabel: String {
        store.carriedGroup != nil ? "Place note" : "Create note"
    }

    private var hintSecondaryLabel: String {
        "Right-click to pick up · drag to move"
    }

    private var hintCycleLabel: String {
        store.carriedGroup != nil ? "Cycle hand" : "Cycle stack"
    }

    private func stringColour(_ index: Int) -> Color {
        let idx = max(0, min(index, WhiteboardStyle.stringColors.count - 1))
        return WhiteboardStyle.stringColors[idx]
    }

    private var stringAlpha: Double {
        store.stringVisibility == .dimmed ? 0.25 : 1.0
    }

    private func linkWidth(for link: Link) -> CGFloat {
        if store.selectedLinkID == link.id { return 4 }
        if store.hoveredLinkID == link.id { return 3.5 }
        return 2
    }

    @ViewBuilder
    private func linkShape(for link: Link) -> some View {
        if let geo = store.curveGeometry(for: link) {
            let curve = LinkCurve(a: geo.a, control: geo.control, b: geo.b)
            curve
                .stroke(
                    stringColour(link.colorIndex).opacity(stringAlpha),
                    style: StrokeStyle(lineWidth: linkWidth(for: link), lineCap: .round)
                )
                // A pinned end tracks its picture exactly; see `Link.touchesPin`.
                .animation(link.touchesPin ? nil : WhiteboardStyle.notePlacementAnimation, value: curve)
        }
    }

    /// A round chip in the floating chrome. There are five of these and they
    /// differed only by symbol and action.
    private func roundChip(
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                .frame(
                    width: WhiteboardStyle.toolbarChipHeight,
                    height: WhiteboardStyle.toolbarChipHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .contentShape(.circle)
        .chromeChip(in: .circle)
    }

    /// The boards in the current project, with the project switcher as its
    /// header.
    private var boardListPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                projectMenu
                Spacer()
                Button {
                    commitPendingRenameIfNeeded()
                    persistence.createBoard()
                    syncStoreBoardMeta()
                    store.clearTransientStateForBoardSwitch()
                } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("New board in this project")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(persistence.boards) { board in
                        BoardRowView(
                            board: board,
                            isActive: store.activeBoardID == board.id,
                            isRenaming: renameBoardID == board.id,
                            renameDraft: $renameDraft,
                            canDelete: persistence.boardCount() > 1,
                            onSelect: {
                                commitPendingRenameIfNeeded()
                                persistence.selectBoard(id: board.id)
                                syncStoreBoardMeta()
                                store.clearTransientStateForBoardSwitch()
                            },
                            onBeginRename: {
                                commitPendingRenameIfNeeded()
                                renameDraft = board.name
                                renameBoardID = board.id
                            },
                            onCommitRename: {
                                persistence.renameBoard(id: board.id, name: renameDraft)
                                renameBoardID = nil
                                syncStoreBoardMeta()
                            },
                            onRequestDelete: {
                                pendingDeleteBoardID = board.id
                                pendingDeleteBoardName = board.name
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 260)
        .confirmationDialog(
            "Delete \"\(pendingDeleteBoardName)\"?",
            isPresented: Binding(
                get: { pendingDeleteBoardID != nil },
                set: { if !$0 { pendingDeleteBoardID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteBoardID {
                    persistence.deleteBoard(id: id)
                    syncStoreBoardMeta()
                    store.clearTransientStateForBoardSwitch()
                }
                pendingDeleteBoardID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteBoardID = nil
            }
        } message: {
            Text("This will remove the board and all its notes. This action cannot be undone.")
        }
        .glassPanel()
    }

    private var showsFieldPanel: Bool {
        store.placementMode == .field || store.selectedFieldID != nil
    }

    /// The project switcher. It takes the place of the panel's old static
    /// "Whiteboards" title so the panel keeps its size: a 260pt panel with a
    /// 260pt-tall list has no room for nested disclosure groups.
    private var projectMenu: some View {
        Menu {
            ForEach(persistence.projects) { project in
                Button {
                    commitPendingRenameIfNeeded()
                    persistence.selectProject(id: project.id)
                    syncStoreBoardMeta()
                    store.clearTransientStateForBoardSwitch()
                } label: {
                    if project.id == persistence.activeProjectID {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button("New Project") {
                commitPendingRenameIfNeeded()
                persistence.createProject()
                syncStoreBoardMeta()
                store.clearTransientStateForBoardSwitch()
            }
            Button("Rename Project…") {
                projectRenameDraft = persistence.activeProjectName
                isRenamingProject = true
            }
            if persistence.projectCount() > 1 {
                Button("Delete Project…", role: .destructive) {
                    isConfirmingProjectDelete = true
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(persistence.activeProjectName.isEmpty ? "Project" : persistence.activeProjectName)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .alert("Rename project", isPresented: $isRenamingProject) {
            TextField("Name", text: $projectRenameDraft)
            Button("Rename") {
                if let id = persistence.activeProjectID {
                    persistence.renameProject(id: id, name: projectRenameDraft)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \"\(persistence.activeProjectName)\"?",
            isPresented: $isConfirmingProjectDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = persistence.activeProjectID {
                    persistence.deleteProject(id: id)
                    syncStoreBoardMeta()
                    store.clearTransientStateForBoardSwitch()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = persistence.projects
                .first { $0.id == persistence.activeProjectID }?.boardCount ?? 0
            Text("This removes the project and its \(count) board\(count == 1 ? "" : "s"), with everything on them. This action cannot be undone.")
        }
    }


    @ViewBuilder
    private func draftShape() -> some View {
        if let draft = store.draftPath() {
            draft.stroke(
                stringColour(store.stringColourPicked).opacity(0.6),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4])
            )
        }
    }

    private var debugLinkSummary: String {
        let total = store.links.count
        var drawable = 0
        for link in store.links.values where store.path(for: link) != nil {
            drawable += 1
        }
        let mode = String(describing: store.placementMode)
        let draft = store.linkDraftSource == nil ? "none" : "ACTIVE"
        let vis = String(describing: store.stringVisibility)
        let notes = store.noteDrawEntries.count
        return "links \(total) · drawable \(drawable) · mode \(mode) · draft \(draft) · vis \(vis) · notes \(notes)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasBackgroundView(store: store)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                // Fields sit behind everything: they are the ground notes stand on.
                // This one draws itself in screen space, so it is not inside the
                // canvas transform and its blend never scales with the zoom.
                FieldLayerView(store: store)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                // Images stand on the fields and sit under the notes. Also a
                // Core Animation layer, also drawn in screen space.
                ImageLayerView(store: store)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                // Reshape / move surface. Its hit area is only the fields themselves,
                // so clicks on empty canvas still reach the background below.
                if store.placementMode != .field {
                    FieldInteractionLayer(store: store)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }

                // Strings layer (plain Shapes, not Canvas: Canvas clips to its own bounds,
                // which hides links whose world coordinates fall outside the viewport rect).
                ZStack(alignment: .topLeading) {
                    FieldLabelsView(store: store)
                    if store.stringVisibility != .hidden {
                        ForEach(Array(store.links.values)) { link in
                            linkShape(for: link)
                        }
                        draftShape()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .scaleEffect(store.canvasScale , anchor: .topLeading)
                .offset(x: store.pixelSnappedPan.width, y: store.pixelSnappedPan.height)
                .allowsHitTesting(false)
                
                // Select / move / resize, in screen space so the outline and
                // handle keep a constant size at any zoom.
                ImageInteractionLayer(store: store)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                ZStack(alignment: .topLeading) {
                    let w = WhiteboardStyle.noteSize.width
                    let h = WhiteboardStyle.noteSize.height
                    ForEach(store.noteDrawEntries) { entry in
                        NoteCardView(store: store, entry: entry)
                            .frame(width: w, height: h)
                            .position(x: entry.worldTopLeft.x + w / 2, y: entry.worldTopLeft.y + h / 2)
                            .animation(WhiteboardStyle.notePlacementAnimation, value: entry.worldTopLeft)
                    }
                }
                .scaleEffect(store.canvasScale , anchor: .topLeading)
                .offset(x: store.pixelSnappedPan.width, y: store.pixelSnappedPan.height)

                // Draft stroke, hover falloff, selection and handles — above the
                // notes, and likewise drawn in screen space.
                FieldOverlayView(store: store)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                // Pins sit above the notes so they stay grabbable even where a
                // note overlaps the picture; the hit area is only the pins
                // themselves, so everything else falls through.
                PinOverlayView(store: store)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                if store.placementMode == .hand {
                    PinInteractionLayer(store: store)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }

                // Pencil: covers the notes so a stroke can be drawn straight across them.
                if store.placementMode == .field {
                    FieldDrawingLayer(store: store)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }

//                ActionLogView(store: store)
                CursorModifierFollowView(
                    cursorInRoot: store.cursorInRoot,
                    viewportSize: proxy.size,
                    shiftHeld: shiftHeld,
                    commandHeld: commandHeld,
                    optionHeld: optionHeld,
                    isEditingNote: store.editingNoteID != nil
                )
                .allowsHitTesting(false)

                if let sid = store.selectedLinkID, let link = store.links[sid], let mid = store.path(for: link)?.approximateMidpoint() {
                    LinkInlineInspector(store: store, link: link)
                        .position(x: mid.x * store.canvasScale + store.pixelSnappedPan.width, y: mid.y * store.canvasScale + store.pixelSnappedPan.height)
                }

                // The note inspector, above the selected note.
                if let noteID = store.selectedNoteID,
                   let note = store.activeNotesByID[noteID],
                   let entry = store.noteDrawEntries.first(where: { $0.noteID == noteID }) {
                    NoteInlineInspector(store: store, note: note)
                        .position(
                            x: (entry.worldTopLeft.x + WhiteboardStyle.noteSize.width / 2)
                                * store.canvasScale + store.pixelSnappedPan.width,
                            y: entry.worldTopLeft.y * store.canvasScale
                                + store.pixelSnappedPan.height - 26
                        )
                }

                if let field = store.field(withID: store.selectedFieldID) {
                    let box = FieldGeometry.bounds(field.ring)
                    let centre = FieldGeometry.centroid(field.ring)
                    FieldInlineInspector(store: store, field: field)
                        .position(
                            x: centre.x * store.canvasScale + store.pixelSnappedPan.width,
                            y: box.minY * store.canvasScale + store.pixelSnappedPan.height - 36
                        )
                }

                VStack {
                    HStack {
                        Spacer()
                        if showsFieldPanel {
                            FieldControlPanel(store: store)
                                .transition(
                                    .scale(scale: 0.94, anchor: .topTrailing)
                                        .combined(with: .opacity)
                                )
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, WhiteboardStyle.chromeInset)
                .padding(.top, WhiteboardStyle.chromeTopInset)
                .animation(WhiteboardStyle.panelAnimation, value: showsFieldPanel)


                // Boards, top left.
                VStack(alignment: .leading) {
                    HStack(alignment: .top, spacing: WhiteboardStyle.chromeSpacing) {
                        roundChip(
                            symbol: isSidebarCollapsed ? "rectangle.stack" : "rectangle.stack.fill",
                            help: "Boards in this project"
                        ) {
                            withAnimation(WhiteboardStyle.panelAnimation) {
                                isSidebarCollapsed.toggle()
                            }
                        }

                        if !isSidebarCollapsed {
                            boardListPanel
                                .transition(
                                    .scale(scale: 0.94, anchor: .topLeading)
                                        .combined(with: .opacity)
                                )
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WhiteboardStyle.chromeInset)
                .padding(.top, WhiteboardStyle.chromeTopInset)

                // The library, bottom left, with image import beside it —
                // adding a picture is what you do with the library open. The
                // panel stacks above them, so the buttons keep the corner.
                VStack(alignment: .leading, spacing: WhiteboardStyle.chromeSpacing) {
                    Spacer(minLength: 0)

                    if !isLibraryCollapsed {
                        LibraryPanelView(
                            store: store,
                            viewportSize: proxy.size,
                            tab: $libraryTab
                        )
                        .transition(
                            .scale(scale: 0.94, anchor: .bottomLeading)
                                .combined(with: .opacity)
                        )
                    }

                    GlassEffectContainer(spacing: WhiteboardStyle.glassContainerSpacing) {
                        HStack(spacing: WhiteboardStyle.chromeSpacing) {
                            roundChip(
                                symbol: isLibraryCollapsed ? "tray.full" : "tray.full.fill",
                                help: "Project library — drag text or images onto the board"
                            ) {
                                withAnimation(WhiteboardStyle.panelAnimation) {
                                    isLibraryCollapsed.toggle()
                                }
                            }
                            roundChip(
                                symbol: "photo.badge.plus",
                                help: "Add an image — or drop a file on the canvas, or paste one (⌘V)"
                            ) {
                                store.presentImageImporter(
                                    atWorld: store.viewportCenterWorld(viewportSize: proxy.size)
                                )
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, WhiteboardStyle.chromeInset)
                .padding(.bottom, WhiteboardStyle.chromeInset)

                // The bottom bar. The tools are centred in the window, so the
                // right-hand group is laid over the top instead of sharing an
                // HStack with them — a spacer between the two would push the
                // tools off-centre by half the right group's width.
                VStack {
                    Spacer(minLength: 0)
                    ZStack {
                        ModifierFlagsMonitor(shift: $shiftHeld, command: $commandHeld, option: $optionHeld)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)

                        GlassEffectContainer(spacing: WhiteboardStyle.glassContainerSpacing) {
                            HStack(spacing: WhiteboardStyle.chromeSpacing) {
                            // The hand leads the row because it is where you
                            // come back to: the note and field tools return
                            // here once they have made something, and so does
                            // Escape.
                            HandToolChip(isActive: store.placementMode == .hand) {
                                store.enterHandMode()
                            }

                            ToolSwatchRow(
                                symbols: .note,
                                colours: WhiteboardStyle.noteBackgrounds,
                                picked: store.noteColourPicked,
                                isActive: store.placementMode == .note,
                                help: "Note — click the canvas to place one (1 · 2 · 3)"
                            ) { store.pickNoteColour($0) }

                            ToolSwatchRow(
                                symbols: .string,
                                colours: WhiteboardStyle.stringColors,
                                picked: store.stringColourPicked,
                                isActive: store.placementMode == .string,
                                help: "String — click two notes to link them (⌘1 · ⌘2 · ⌘3)"
                            ) { store.pickStringColour($0) }

                            // Picking a field colour takes up the pencil; picking a note
                            // or string colour puts it back down.
                            ToolSwatchRow(
                                symbols: .field,
                                colours: WhiteboardStyle.fieldFills,
                                picked: store.fieldColourPicked,
                                isActive: store.placementMode == .field,
                                help: "Field — drag to draw a zone (⌥1 · ⌥2 · ⌥3)"
                            ) { store.pickFieldColour($0) }

                            }
                        }

                        HStack {
                            Spacer(minLength: 0)
                            GlassEffectContainer(spacing: WhiteboardStyle.glassContainerSpacing) {
                                HStack(spacing: WhiteboardStyle.chromeSpacing) {
                                    Button {
                                        store.animateZoomReset(viewportSize: proxy.size)
                                    } label: {
                                        Label(
                                            "\(Int(store.canvasScale * 100))%",
                                            systemImage: "plus.magnifyingglass"
                                        )
                                        .font(.system(size: WhiteboardStyle.toolbarSymbolSize - 4, weight: .semibold))
                                        .padding(.horizontal, 14)
                                        .frame(height: WhiteboardStyle.toolbarChipHeight)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Reset zoom to 100% (viewport center)")
                                    .contentShape(.capsule)
                                    // The effect first, then the ID naming it.
                                    .chromeChip(in: .capsule)
                                    .glassEffectID("zoom", in: keyboardHints)

                                    roundChip(
                                        symbol: store.stringVisibility.symbolName,
                                        help: "Toggle strings: Hidden / Dimmed / Full"
                                    ) {
                                        store.cycleStringVisibility()
                                    }

                                    HomeCompassHUD(store: store, viewportSize: proxy.size)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WhiteboardStyle.chromeInset)
                .padding(.bottom, WhiteboardStyle.chromeInset)


                // Debug HUD — toggled from the Developer menu (⇧⌘D).
                if showDebugHUD {
                    VStack {
                        Text(debugLinkSummary)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.75), in: Capsule())
                            .padding(.top, 8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "root")
            // Panels read this to stand their blur down mid-gesture.
            .environment(\.canvasIsMoving, store.isCanvasMoving)
            .dropDestination(for: CanvasDrop.self) { drops, location in
                let world = store.rootToWorld(location)
                var files: [URL] = []
                for drop in drops {
                    switch drop {
                    case .file(let url) where url.isFileURL:
                        files.append(url)
                    case .file:
                        break
                    case .libraryItem(let payload):
                        switch payload.kind {
                        case .image: store.placeImageResource(payload.resourceID, atWorld: world)
                        case .text: store.placeTextResource(payload.resourceID, atWorld: world)
                        }
                    }
                }
                if !files.isEmpty { store.importImages(from: files, atWorld: world) }
                return true
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background {
                ZStack {
                    CanvasCursorMonitor(store: store)
                    CanvasRightClickMonitor(store: store)
                    CanvasScrollPanMonitor(store: store)
                    CanvasPinchZoomMonitor(store: store)
                    CanvasKeyboardCycleMonitor(store: store)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    store.updateCursor(location)
                    if store.linkDraftSource != nil {
                        store.updateLinkDraft(to: location)
                    }
                case .ended:
                    store.hoveredLinkID = nil
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: renameBoardID) { _, id in
            store.isBoardListRenaming = (id != nil)
        }
        .onAppear {
            store.attachUndoManager(undoManager)
            // Locating a use on another board switches to it, which needs the
            // same reload as clicking it in the sidebar.
            store.onBoardSwitched = {
                syncStoreBoardMeta()
                store.clearTransientStateForBoardSwitch()
            }
            // A note joining the library, or being duplicated or deleted,
            // changes the library from the persistence side.
            persistence.onLibraryChanged = { store.reloadTextResources() }
            persistence.onTextResourceEdited = { id, text in
                store.noteTextResourceEdited(id, text: text)
            }
            guard !didBootstrap else { return }
            didBootstrap = true
            store.persistence = persistence
            persistence.configure(context: modelContext)
            persistence.bootstrap()
            syncStoreBoardMeta()
            store.canvasPan = persistence.activeCanvasPan
            store.canvasScale = persistence.activeCanvasScale
        }
        .onChange(of: store.canvasPan) { _, pan in
            persistence.setCanvasPan(pan)
        }
        .onChange(of: store.activeGroups) { _, _ in
            // Notes moved, were created or deleted: field membership may have changed.
            store.rebuildFieldMembership()
        }
        .onChange(of: store.canvasScale) { _, scale in
            persistence.setCanvasScale(scale)
        }
        .onDisappear {
            persistence.flushPendingSaves()
        }
    }

    private func syncStoreBoardMeta() {
        store.activeBoardID = persistence.activeBoardID
        store.activeBoardName = persistence.activeBoardName
        // Resources are project-scoped, so the library loads before the board:
        // placements are hydrated from the resources they point at.
        store.activeProjectID = persistence.activeProjectID
        store.loadLibraryForActiveProject()
        store.loadLinksForActiveBoard()
        store.loadFieldsForActiveBoard()
        store.loadImagesForActiveBoard()
        store.loadPinsForActiveBoard()
    }

    /// Commits any in-progress inline board rename (e.g. before selecting another board or starting a new rename).
    private func commitPendingRenameIfNeeded() {
        guard let id = renameBoardID else { return }
        persistence.renameBoard(id: id, name: renameDraft)
        renameBoardID = nil
        syncStoreBoardMeta()
    }
}

// MARK: - Board list row

private struct BoardRowView: View {
    let board: BoardSummary
    let isActive: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    let canDelete: Bool
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onRequestDelete: () -> Void

    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isRenaming {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit(onCommitRename)
                    .onAppear { renameFocused = true }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused && isRenaming {
                            onCommitRename()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(board.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "square.on.square")
                .foregroundStyle(.secondary)
            Text("\(board.noteCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.white.opacity(0.14) : Color.clear)
        )
        .onTapGesture {
            if isRenaming { return }
            onSelect()
        }
        .contextMenu {
            Button {
                onBeginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canDelete)
        }
    }
}

// MARK: - Home / compass HUD

private struct CursorModifierFollowView: View {
    let cursorInRoot: CGPoint
    let viewportSize: CGSize
    let shiftHeld: Bool
    let commandHeld: Bool
    let optionHeld: Bool
    let isEditingNote: Bool

    private let indicatorWidth: CGFloat = 78
    private let indicatorHeight: CGFloat = 20
    private let cursorOffset = CGSize(width: -16, height: 4)

    private var hasVisibleModifiers: Bool {
        shiftHeld || optionHeld || commandHeld
    }

    private var indicatorX: CGFloat {
        let x = cursorInRoot.x + cursorOffset.width - (indicatorWidth / 2)
        return min(max(x, indicatorWidth / 2), viewportSize.width - (indicatorWidth / 2))
    }

    private var indicatorY: CGFloat {
        let y = cursorInRoot.y + cursorOffset.height
        return min(max(y, indicatorHeight / 2), viewportSize.height - (indicatorHeight / 2))
    }

    var body: some View {
        if hasVisibleModifiers && !isEditingNote {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if shiftHeld {
                    Image(systemName: "shift.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                if optionHeld {
                    Image(systemName: "option")
                        .font(.system(size: 14, weight: .semibold))
                }
                if commandHeld {
                    Image(systemName: "command")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(width: indicatorWidth, alignment: .leading)
            .foregroundStyle(.blue)
            .position(x: indicatorX, y: indicatorY)
        }
    }
}

private struct HomeCompassHUD: View {
    @ObservedObject var store: WhiteboardStore
    var viewportSize: CGSize

    var body: some View {
        let onScreen = store.isContentCenterOnScreen(viewportSize: viewportSize)
        let bearing = store.bearingToContentCenter(viewportSize: viewportSize)
        let hasContent = store.contentCenterWorld() != nil

        Button {
            store.animateCenterToContent(viewportSize: viewportSize)
        } label: {
            Image(systemName: onScreen ? "viewfinder" : "location.north.fill")
                .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                .rotationEffect(onScreen ? .zero : .radians(Double(bearing ?? 0)))
                .animation(.easeInOut(duration: 0.1), value: bearing ?? 0)
                .foregroundStyle(hasContent ? Color.white : Color.gray.opacity(0.45))
                .frame(
                    width: WhiteboardStyle.toolbarChipHeight,
                    height: WhiteboardStyle.toolbarChipHeight
                )
                .contentShape(Rectangle())
        }
        .disabled(!hasContent)
        .buttonStyle(.plain)
        .help(onScreen ? "Center on content" : "Compass: tap to recenter")
        .contentShape(.circle)
        .chromeChip(in: .circle)
    }
}

/// Quad curve whose endpoints and control point interpolate, so a string glides
/// to its new shape when a connected note is picked up or placed.
private struct LinkCurve: Shape, Equatable {
    var a: CGPoint
    var control: CGPoint
    var b: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>> {
        get {
            AnimatablePair(a.animatableData, AnimatablePair(control.animatableData, b.animatableData))
        }
        set {
            a.animatableData = newValue.first
            control.animatableData = newValue.second.first
            b.animatableData = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: control)
        return p
    }
}

private extension Path {
    func approximateMidpoint(samples: Int = 20) -> CGPoint {
        let box = boundingRect
        guard box.width > 0 || box.height > 0 else { return CGPoint(x: box.midX, y: box.midY) }
        // Crude midpoint: sample along x in bbox and pick the middle of stroked path
        return CGPoint(x: box.midX, y: box.midY)
    }
}

private struct LinkInlineInspector: View {
    @ObservedObject var store: WhiteboardStore
    let link: Link
    @State private var labelDraft: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Label", text: Binding(
                get: { link.label ?? labelDraft },
                set: { labelDraft = $0; store.setSelectedLinkLabel($0) }
            ))
            .capsuleField(width: 132)

            ForEach(0..<3) { idx in
                Button {
                    store.setSelectedLinkColor(index: idx)
                } label: {
                    Circle()
                        .fill(WhiteboardStyle.stringColors[idx])
                        .colourDot(isSelected: link.colorIndex == idx)
                }
                .buttonStyle(.plain)
            }

            Button(role: .destructive) {
                store.deleteSelectedLink()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
    }
}
