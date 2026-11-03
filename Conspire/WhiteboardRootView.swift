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
    @AppStorage("showDebugHUD") private var showDebugHUD: Bool = false
    @State private var didBootstrap = false
    @State private var renameBoardID: UUID?
    @State private var renameDraft: String = ""
    @State private var pendingDeleteBoardID: UUID?
    @State private var pendingDeleteBoardName: String = ""
    
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
                .animation(WhiteboardStyle.notePlacementAnimation, value: curve)
        }
    }

    @ViewBuilder
    private func hoveredLinkDeleteButton() -> some View {
        if store.stringVisibility != .hidden,
           store.carriedGroup == nil,
           let hoveredID = store.hoveredLinkID,
           let link = store.links[hoveredID],
           let mid = store.midpoint(for: link) {
            Button {
                store.removeLink(hoveredID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, stringColour(link.colorIndex))
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Delete string")
            .position(x: mid.x, y: mid.y)
            .animation(WhiteboardStyle.notePlacementAnimation, value: mid)
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

                // Delete affordance for the hovered string, above notes so it stays clickable.
                ZStack(alignment: .topLeading) {
                    hoveredLinkDeleteButton()
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .scaleEffect(store.canvasScale , anchor: .topLeading)
                .offset(x: store.pixelSnappedPan.width, y: store.pixelSnappedPan.height)

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

                if let field = store.field(withID: store.selectedFieldID) {
                    let box = FieldGeometry.bounds(field.ring)
                    let centre = FieldGeometry.centroid(field.ring)
                    FieldInlineInspector(store: store, field: field)
                        .position(
                            x: centre.x * store.canvasScale + store.pixelSnappedPan.width,
                            y: box.minY * store.canvasScale + store.pixelSnappedPan.height - 36
                        )
                }

                if store.placementMode == .field || store.selectedFieldID != nil {
                    VStack {
                        HStack {
                            Spacer()
                            FieldControlPanel(store: store)
                        }
                        Spacer()
                    }
                    .padding(24)
                }

                VStack (alignment: .leading){
                    Spacer()
                    
                    HStack {
                        GlassEffectContainer {
                            VStack(alignment: .leading, spacing: 10) {
                                
                                if !isSidebarCollapsed {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("Whiteboards").font(.headline)
                                            Spacer()
                                            Button {
                                                commitPendingRenameIfNeeded()
                                                persistence.createBoard()
                                                syncStoreBoardMeta()
                                                store.clearTransientStateForBoardSwitch()
                                            } label: { Image(systemName: "plus") }
                                            .buttonStyle(.plain)
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
        //                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                                    .glassEffectUnion(id: "sidebar", namespace: keyboardHints)
                                }
                                
                                Button {
                                    withAnimation {
                                        isSidebarCollapsed.toggle()
                                    }
                                } label: {
                                    Image(systemName: isSidebarCollapsed ? "rectangle.stack" : "rectangle.stack")
                                        .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                                        .padding(12)
                                        .contentShape(Rectangle())
                                        .frame(
                                            width: WhiteboardStyle.toolbarChipHeight,
                                            height: WhiteboardStyle.toolbarChipHeight
                                        )
                                }
                                .buttonStyle(.plain)
        //                        .glassEffect(.regular, in: .circle)
                                .glassEffectUnion(id: "sidebar", namespace: keyboardHints)

                                Button {
                                    store.cycleStringVisibility()
                                } label: {
                                    Image(systemName: store.stringVisibility.symbolName)
                                        .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                                        .padding(12)
                                        .contentShape(Rectangle())
                                        .frame(
                                            width: WhiteboardStyle.toolbarChipHeight,
                                            height: WhiteboardStyle.toolbarChipHeight
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Toggle strings: Hidden / Dimmed / Full")
                                .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                            .padding(24)
                            .padding(.bottom, 54)
                        }
                        
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
                
                VStack(alignment: .center) {
                    Spacer()
                    
                    
                    
                    GlassEffectContainer {
                        HStack(spacing: WhiteboardStyle.toolbarSpacing) {
                            ModifierFlagsMonitor(shift: $shiftHeld, command: $commandHeld, option: $optionHeld)
                                .frame(width: 0, height: 0)
                                .allowsHitTesting(false)
                            
//                            ModifierKeyTooltip(shift: $shiftHeld, command: $commandHeld, option: $optionHeld)
//                                .glassEffectID("modifiers", in: keyboardHints)
//                                .padding(.horizontal, 16)
//                                .padding(.vertical, 12)
//                                .glassEffect()

                            Spacer()
                        
                            
                            // TODO: Make icons stay in place when text changes. Might need to separate Text from Image to do so.
//                            HStack {
//                                Label(hintPrimaryLabel, systemImage: "cursorarrow.click")
//                                    .frame(width: 120, alignment: .leading)
////                                    .glassEffect()
//                                    .glassEffectUnion(id: "hints", namespace: keyboardHints)
//                                Label(hintSecondaryLabel, systemImage: "cursorarrow.click.2")
//                                    .frame(width: 120, alignment: .leading)
////                                    .glassEffect()
//                                    .glassEffectUnion(id: "hints", namespace: keyboardHints)
//                                Label(hintCycleLabel, systemImage: "arrow.right.to.line")
//                                    .frame(width: 100, alignment: .leading)
////                                    .glassEffect()
//                                    .glassEffectUnion(id: "hints", namespace: keyboardHints)
//                            }
//                            .padding(.horizontal, 16)
//                            .padding(.vertical, 12)
//                            .glassEffect()
                            
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
                                help: "Note — click the canvas to place one (1 · 2 · 3)",
                                unionID: "notecolors",
                                namespace: keyboardHints
                            ) { store.pickNoteColour($0) }

                            ToolSwatchRow(
                                symbols: .string,
                                colours: WhiteboardStyle.stringColors,
                                picked: store.stringColourPicked,
                                isActive: store.placementMode == .string,
                                help: "String — click two notes to link them (⌘1 · ⌘2 · ⌘3)",
                                unionID: "stringcolors",
                                namespace: keyboardHints
                            ) { store.pickStringColour($0) }

                            // Picking a field colour takes up the pencil; picking a note
                            // or string colour puts it back down.
                            ToolSwatchRow(
                                symbols: .field,
                                colours: WhiteboardStyle.fieldFills,
                                picked: store.fieldColourPicked,
                                isActive: store.placementMode == .field,
                                help: "Field — drag to draw a zone (⌥1 · ⌥2 · ⌥3)",
                                unionID: "fieldcolors",
                                namespace: keyboardHints
                            ) { store.pickFieldColour($0) }

                            Spacer()
                            
                            // An action, not a tool, so it lives with the
                            // zoom and compass rather than among the tool
                            // chips — nothing in the left group should be a
                            // chip that never fills.
                            Button {
                                store.presentImageImporter(
                                    atWorld: store.viewportCenterWorld(viewportSize: proxy.size)
                                )
                            } label: {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .frame(height: WhiteboardStyle.toolbarChipHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Add an image — or drop a file on the canvas, or paste one (⌘V)")
                            .glassEffect()

                            Button {
                                store.animateZoomReset(viewportSize: proxy.size)
                            } label: {
                                Label("\(Int(store.canvasScale*100))%", systemImage: "plus.magnifyingglass")
                                    .font(.system(size: WhiteboardStyle.toolbarSymbolSize-4, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .frame(height: WhiteboardStyle.toolbarChipHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Reset zoom to 100% (viewport center)")
                            .glassEffectID("zoom", in: keyboardHints)
                            .glassEffect()
                            
                            HomeCompassHUD(store: store, viewportSize: proxy.size)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)

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
            .dropDestination(for: URL.self) { urls, location in
                store.importImages(
                    from: urls.filter(\.isFileURL),
                    atWorld: store.rootToWorld(location)
                )
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
        .glassEffect(.regular.interactive(), in: .circle)
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
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)

            ForEach(0..<3) { idx in
                Button {
                    store.setSelectedLinkColor(index: idx)
                } label: {
                    Circle()
                        .fill(WhiteboardStyle.stringColors[idx])
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }

            Button(role: .destructive) {
                store.deleteSelectedLink()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6)
    }
}
