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

    /// Marks a note whose words are shared with somewhere else, because editing
    /// it will change there too.
    ///
    /// Every note is a library item, so showing this whenever one exists would
    /// put the same badge on every card and say nothing. It appears only when
    /// the item is actually on more than one note.
    @ViewBuilder
    private var libraryChip: some View {
        let resourceID = store.activeNotesByID[entry.noteID]?.textResourceID
        if isBoardStackEntry, entry.isTop, store.noteIsSharedWithAnotherPlace(resourceID) {
            let count = store.textUseCount(resourceID ?? UUID())
            HStack(spacing: 2) {
                Image(systemName: "tray.full.fill")
                Text("\(count)").monospacedDigit()
            }
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.black.opacity(0.45))
            .help("Shared with \(count - 1) other note\(count == 2 ? "" : "s") — editing changes them too")
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

    var body: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: WhiteboardStyle.cornerRadius)
                .fill(noteBackgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: WhiteboardStyle.cornerRadius)
                        .stroke(outlineColor, lineWidth: outlineWidth)
                }

            if let stamp = store.activeNotesByID[entry.noteID]?.stamp {
                Image(systemName: stamp)
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
                        // Asserted on the next tick, not during the appear: the
                        // second half of the double-click that started editing
                        // lands after the field exists and takes focus back.
                        Task { @MainActor in isTextEditorFocused = true }
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
        .onTapGesture(count: 2) {
            // Double-click to edit the words. This replaces the pencil button
            // that used to sit on the card, and is the gesture people try
            // first anyway.
            guard store.carriedGroup == nil, isBoardStackEntry else { return }
            store.selectNote(nil)
            store.startEditing(note: entry.noteID)
        }
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
            // In the hand, a click selects — which is what gives the note an
            // inspector like every other object on the canvas.
            if isBoardStackEntry, store.placementMode == .note {
                store.createNoteOnTopOfBoardStack(groupID: entry.groupID)
            } else if isBoardStackEntry {
                store.stopEditing()
                store.selectNote(entry.noteID)
            } else {
                store.stopEditing()
            }
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                Task { @MainActor in isTextEditorFocused = true }
            } else {
                isTextEditorFocused = false
            }
        }
        .onDisappear {
            if isDraggingWithGrabCursor {
                NSCursor.pop()
                isDraggingWithGrabCursor = false
            }
        }
    }
}


/// Colour, stamp and delete for the selected note.
///
/// These were three buttons on the card itself — a trash can, a stamp toggle
/// and a pencil — appearing on hover and competing with the note's own text,
/// with the stamp picker hidden behind a right-click on one of them. Notes were
/// the only object on the canvas without a selection, which is why their
/// controls had nowhere else to live. Now they have one, like fields, strings
/// and images.
struct NoteInlineInspector: View {
    @ObservedObject var store: WhiteboardStore
    let note: NoteRender

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<WhiteboardStyle.noteBackgrounds.count, id: \.self) { index in
                Button {
                    store.setSelectedNoteColour(index)
                } label: {
                    Circle()
                        .fill(WhiteboardStyle.noteBackgrounds[index])
                        .colourDot(isSelected: note.colour == index)
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 14)

            Menu {
                if note.stamp != nil {
                    Button("No stamp") { store.setSelectedNoteStamp(nil) }
                    Divider()
                }
                ForEach(NoteStamp.symbols, id: \.self) { symbol in
                    Button {
                        store.setSelectedNoteStamp(symbol)
                    } label: {
                        Label(NoteStamp.name(for: symbol), systemImage: symbol)
                    }
                }
            } label: {
                // Fixed box: SF Symbols differ in width, so without this the
                // capsule resized every time the stamp changed, and again on
                // hover — which read as the whole inspector jittering.
                Image(systemName: note.stamp ?? "seal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(note.stamp == nil ? .secondary : .primary)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Stamp — the faint symbol behind the note's text")

            Divider().frame(height: 14)

            Button(role: .destructive) {
                let id = note.id
                store.selectNote(nil)
                store.deleteNote(id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Delete note")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
    }
}
