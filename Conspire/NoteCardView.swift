//
//  NoteCardView.swift
//  Conspire
//

import SwiftUI
import AppKit

struct NoteCardView: View {
    @ObservedObject var store: WhiteboardStore
    let entry: NoteDrawEntry
    @FocusState private var isTextEditorFocused: Bool
    @State private var stampSymbol: String = "checkmark"
    @State private var stampActive: Bool = false
    @State private var dragGestureActive = false
    @State private var isDraggingWithGrabCursor = false

    private var text: String {
        store.activeNotesByID[entry.noteID]?.text ?? ""
    }

    private var noteBackgroundColor: Color {
        guard let colourIndex = store.activeNotesByID[entry.noteID]?.colour else {
            return WhiteboardStyle.noteBackground
        }
        guard WhiteboardStyle.noteBackgrounds.indices.contains(colourIndex) else {
            return WhiteboardStyle.noteBackground
        }
        return WhiteboardStyle.noteBackgrounds[colourIndex]
    }

    private var noteOutlineColor: Color {
        guard let colourIndex = store.activeNotesByID[entry.noteID]?.colour else {
            return WhiteboardStyle.hoverOutlineColor
        }
        guard WhiteboardStyle.hoverOutlineColors.indices.contains(colourIndex) else {
            return WhiteboardStyle.hoverOutlineColor
        }
        return WhiteboardStyle.hoverOutlineColors[colourIndex]
    }

    private var isEditing: Bool {
        store.editingNoteID == entry.noteID
    }

    private var isBoardStackEntry: Bool {
        !entry.isCarried && !entry.isStampPlacementOverlay
    }

    /// Fields this note sits inside. Read from the store's cache rather than
    /// recomputed here — this runs for every note on every render.
    private var containingFields: [FieldChip] {
        guard isBoardStackEntry, entry.isTop else { return [] }
        return store.noteFieldChips[entry.noteID] ?? []
    }

    /// Marks a note whose words come from the text library, because editing it
    /// changes every board showing that item — worth knowing before you type.
    @ViewBuilder
    private var libraryChip: some View {
        if isBoardStackEntry, entry.isTop,
           store.activeNotesByID[entry.noteID]?.textResourceID != nil {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.black.opacity(0.4))
                .help("From the project library — editing this changes it everywhere")
        }
    }

    @ViewBuilder
    private var fieldChips: some View {
        let fields = containingFields
        if !fields.isEmpty {
            HStack(spacing: 3) {
                ForEach(fields) { field in
                    Text(field.label)
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(FieldPalette.edge(field.colourIndex).opacity(0.92), in: Capsule())
                        .frame(maxWidth: 62, alignment: .leading)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var stackHovered: Bool {
        store.hoveredGroupID == entry.groupID && isBoardStackEntry
    }

    private var showHoverOutline: Bool {
        stackHovered && entry.isTop
    }

    private var outlineColor: Color {
        if isEditing {
            return noteOutlineColor.mix(with: .black, by: WhiteboardStyle.focusOutlineDarkening)
        }
        return showHoverOutline ? noteOutlineColor : Color.black.opacity(0.12)
    }

    private var outlineWidth: CGFloat {
        if isEditing { return WhiteboardStyle.focusOutlineWidth }
        return showHoverOutline ? WhiteboardStyle.hoverOutlineWidth : 1
    }

    private func selectStamp(_ symbol: String) {
        stampSymbol = symbol
        stampActive = true
    }

    @ViewBuilder
    private var stampPickerMenu: some View {
        Button { selectStamp("lightbulb") } label: { Label("Lightbulb", systemImage: "lightbulb") }
        Button { selectStamp("xmark") } label: { Label("X", systemImage: "xmark") }
        Button { selectStamp("questionmark") } label: { Label("Question", systemImage: "questionmark") }
        Button { selectStamp("exclamationmark") } label: { Label("Exclamation", systemImage: "exclamationmark") }
        Button { selectStamp("text.bubble") } label: { Label("Comment", systemImage: "text.bubble") }
        Button { selectStamp("link") } label: { Label("Link", systemImage: "link") }
        ControlGroup {
            Button { selectStamp("circle") } label: { Image(systemName: "circle") }
            Button { selectStamp("square") } label: { Image(systemName: "square") }
            Button { selectStamp("triangleshape") } label: { Image(systemName: "triangleshape") }
        }
        Button { selectStamp("sparkles") } label: { Label("Sparkles", systemImage: "sparkles") }
        Button { selectStamp("ladybug") } label: { Label("Bug", systemImage: "ladybug") }
        ControlGroup {
            Button { selectStamp("arrow.triangle.swap") } label: { Image(systemName: "arrow.triangle.swap") }
            Button { selectStamp("arrow.triangle.merge") } label: { Image(systemName: "arrow.triangle.merge") }
            Button { selectStamp("arrow.triangle.branch") } label: { Image(systemName: "arrow.triangle.branch") }
        }
        Button { selectStamp("magnifyingglass") } label: { Label("Search", systemImage: "magnifyingglass") }
        Button { selectStamp("flame") } label: { Label("Flame", systemImage: "flame") }
        Button { selectStamp("snowflake") } label: { Label("Snowflake", systemImage: "snowflake") }
    }

    var body: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: WhiteboardStyle.cornerRadius)
                .fill(noteBackgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: WhiteboardStyle.cornerRadius)
                        .stroke(outlineColor, lineWidth: outlineWidth)
                }

            if stampActive {
                Image(systemName: stampSymbol)
                    .foregroundStyle(.black.opacity(0.12))
                    .font(.system(size: 80))
            }
            
            Group {
                if isEditing {
                    TextField(
                        "",
                        text: Binding(
                            get: { store.activeNotesByID[entry.noteID]?.text ?? "" },
                            set: { store.updateNoteText(note: entry.noteID, text: $0) }
                        ),
                        axis: .vertical
                    )
                    .font(.body)
                    .foregroundColor(.black)
                    .multilineTextAlignment(.center)
                    .lineLimit(1...WhiteboardStyle.displayMaxLines)
                    .textFieldStyle(.plain)
                    .padding(WhiteboardStyle.textPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .focused($isTextEditorFocused)
                    .onAppear {
                        isTextEditorFocused = true
                    }
                } else {
                    Text(text.isEmpty ? " " : text)
                        .font(.body)
                        .foregroundStyle(.black)
                        .multilineTextAlignment(.center)
                        .lineLimit(WhiteboardStyle.displayMaxLines)
                        .truncationMode(.tail)
                        .padding(WhiteboardStyle.textPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }

            // Field membership, top-left: the hover affordances live elsewhere on the card.
            VStack {
                HStack {
                    fieldChips
                    Spacer()
                    libraryChip
                }
                Spacer()
            }
            .padding(5)

            if entry.isTop && stackHovered {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            store.deleteNote(entry.noteID)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.black)
                                .frame(width: WhiteboardStyle.editButtonSize, height: WhiteboardStyle.editButtonSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete note")
                    }

                    Spacer()
                    HStack {
                        Button {
                            stampActive.toggle()
                        } label: {
                            Image(systemName: stampActive ? "xmark" : stampSymbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.black)
                                .frame(width: WhiteboardStyle.editButtonSize, height: WhiteboardStyle.editButtonSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Toggle stamp (right-click for options)")
                        .contextMenu {
                            stampPickerMenu
                        }
                        
                        Spacer()
                        Button {
                            store.startEditing(note: entry.noteID)
                        } label: {
                            Image(systemName: "pencil.line")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.black)
                                .frame(width: WhiteboardStyle.editButtonSize, height: WhiteboardStyle.editButtonSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Edit note")
                    }
                }
                .padding(4)
            }
        }
        .frame(width: WhiteboardStyle.noteSize.width, height: WhiteboardStyle.noteSize.height)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("root"))
                .onChanged { value in
                    guard !entry.isCarried else { return }
                    if !dragGestureActive {
                        if store.beginDrag(
                            groupID: entry.groupID,
                            atRootPoint: value.startLocation,
                            modifiers: InputModifiers.current()
                        ) {
                            dragGestureActive = true
                            if !isDraggingWithGrabCursor {
                                NSCursor.closedHand.push()
                                isDraggingWithGrabCursor = true
                            }
                        }
                    } else {
                        store.updateDrag(atRootPoint: value.location)
                    }
                }
                .onEnded { value in
                    if dragGestureActive {
                        dragGestureActive = false
                        store.endDrag(atRootPoint: value.location)
                    }
                    if isDraggingWithGrabCursor {
                        NSCursor.pop()
                        isDraggingWithGrabCursor = false
                    }
                }
        )
        .onTapGesture {
            // Holding notes trumps every creation interaction: the click always means "place".
            if store.carriedGroup != nil {
                if isBoardStackEntry {
                    store.handlePrimaryTapOnBoardGroup(groupID: entry.groupID)
                } else {
                    store.stopEditing()
                }
                return
            }
            // String mode (or Command-click as a shortcut into it): start or commit a link from/to this note
            if store.placementMode == .string || InputModifiers.current().command {
                let nodeID: NodeID = .note(entry.noteID)
                if store.linkDraftSource == nil {
                    store.beginLink(from: nodeID)
                } else {
                    store.commitLink(to: nodeID)
                }
                return
            }
            // Adding to a stack is creation, so it belongs to the note tool.
            // In the hand it is an ordinary click: stop editing, nothing more.
            if isBoardStackEntry, store.placementMode == .note {
                store.createNoteOnTopOfBoardStack(groupID: entry.groupID)
            } else {
                store.stopEditing()
            }
        }
        .onChange(of: isEditing) { _, editing in
            isTextEditorFocused = editing
        }
        .onDisappear {
            if isDraggingWithGrabCursor {
                NSCursor.pop()
                isDraggingWithGrabCursor = false
            }
        }
    }
}

