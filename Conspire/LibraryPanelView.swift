//
//  LibraryPanelView.swift
//  Conspire
//

import SwiftUI

enum LibraryTab: String, CaseIterable {
    case text
    case images

    var label: String {
        switch self {
        case .text: return "Text"
        case .images: return "Images"
        }
    }
}

/// The project's shared resources, beside the boards panel.
///
/// A panel rather than a sheet, deliberately: the whole point is to drag items
/// onto the board, and a modal would cover the board you are aiming at.
struct LibraryPanelView: View {
    @ObservedObject var store: WhiteboardStore
    let viewportSize: CGSize
    @Binding var tab: LibraryTab

    @State private var search = ""
    @State private var showingUsesFor: UUID?
    @State private var newTextDraft = ""
    @State private var isAddingText = false
    @State private var pendingDelete: (id: UUID, kind: LibraryDragPayload.Kind, uses: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            content
        }
        .padding(12)
        .frame(width: 300)
        .modifier(PanelBackground(cornerRadius: 20))
        .alert("New text item", isPresented: $isAddingText) {
            TextField("Text", text: $newTextDraft)
            Button("Add") {
                let trimmed = newTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { store.addTextResource(trimmed) }
                newTextDraft = ""
            }
            Button("Cancel", role: .cancel) { newTextDraft = "" }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pending = pendingDelete {
                    switch pending.kind {
                    case .image: store.deleteImageResource(pending.id)
                    case .text: store.deleteTextResource(pending.id)
                    }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteTitle: String {
        guard let pending = pendingDelete else { return "" }
        return pending.kind == .image ? "Remove this image?" : "Remove this text?"
    }

    private var deleteMessage: String {
        guard let pending = pendingDelete else { return "" }
        let uses = pending.uses
        switch pending.kind {
        case .image where uses == 0:
            return "It is not on any board."
        case .image:
            return "It is on \(uses) board\(uses == 1 ? "" : "s"), and will be removed from "
                + "\(uses == 1 ? "it" : "them") too. This cannot be undone."
        case .text where uses == 0:
            return "It is not on any board."
        case .text:
            // Notes keep the words they were showing: a board the user is not
            // looking at should not quietly empty itself.
            return "\(uses) note\(uses == 1 ? "" : "s") came from it. "
                + "\(uses == 1 ? "It keeps" : "They keep") the text but stop being linked."
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(LibraryTab.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == .text {
                Button {
                    isAddingText = true
                } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("New text item")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            switch tab {
            case .images: imageGrid
            case .text: textList
            }
        }
        .frame(maxHeight: 260)
    }

    // MARK: - Images

    private var filteredImages: [ImageResource] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return store.imageResources }
        return store.imageResources.filter { $0.name.lowercased().contains(term) }
    }

    @ViewBuilder
    private var imageGrid: some View {
        if store.imageResources.isEmpty {
            emptyNote("Drop a picture on the board and it appears here.")
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(filteredImages) { resource in
                    LibraryThumbnail(image: store.imageThumbnails[resource.id])
                        .overlay(alignment: .bottomTrailing) { useBadge(count: nil) }
                        .draggable(
                            LibraryDragPayload(kind: .image, resourceID: resource.id)
                        ) {
                            LibraryThumbnail(image: store.imageThumbnails[resource.id])
                        }
                        .onTapGesture { showingUsesFor = resource.id }
                        .popover(isPresented: usesBinding(for: resource.id)) {
                            usesPopover(
                                uses: store.imageUses(of: resource.id),
                                title: resource.name,
                                onDelete: {
                                    pendingDelete = (
                                        resource.id, .image, store.imageUses(of: resource.id).count
                                    )
                                }
                            )
                        }
                        .help(resource.name)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Text

    private var filteredText: [TextResource] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return store.textResources }
        return store.textResources.filter { $0.text.lowercased().contains(term) }
    }

    @ViewBuilder
    private var textList: some View {
        if store.textResources.isEmpty {
            emptyNote("Add a code or a quote, then drag it onto a board.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(filteredText) { resource in
                    let uses = store.textUses(of: resource.id)
                    HStack(alignment: .top, spacing: 6) {
                        Text(resource.text)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !uses.isEmpty {
                            Text("\(uses.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                    .draggable(LibraryDragPayload(kind: .text, resourceID: resource.id)) {
                        Text(resource.text).lineLimit(1).padding(6)
                    }
                    .onTapGesture { showingUsesFor = resource.id }
                    .popover(isPresented: usesBinding(for: resource.id)) {
                        usesPopover(
                            uses: uses,
                            title: resource.text,
                            onDelete: {
                                pendingDelete = (resource.id, .text, uses.count)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Shared pieces

    private func usesBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { showingUsesFor == id },
            set: { if !$0 && showingUsesFor == id { showingUsesFor = nil } }
        )
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func useBadge(count: Int?) -> some View {
        if let count, count > 1 {
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.black.opacity(0.6)))
                .foregroundStyle(.white)
                .padding(3)
        }
    }

    private func usesPopover(
        uses: [ResourceUse], title: String, onDelete: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)

            if uses.isEmpty {
                Text("Not on any board yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(uses.count) use\(uses.count == 1 ? "" : "s")")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                // One row per appearance, not per board: the same code used
                // twice on one board is two places you might want to go.
                ForEach(uses) { use in
                    HStack(spacing: 6) {
                        Text(use.boardName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        if use.isOnActiveBoard {
                            Text("open")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Locate") {
                            showingUsesFor = nil
                            store.locate(use, viewportSize: viewportSize)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            }

            Divider()
            Button("Remove from Library", role: .destructive) {
                showingUsesFor = nil
                onDelete()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.red)
        }
        .padding(12)
        .frame(width: 250)
    }
}

/// A library preview: every tile the same flat rectangle, with the picture
/// scaled to fill and clipped. Uniform tiles read as a row of previews; the
/// real aspect ratios would read as a ragged collage.
struct LibraryThumbnail: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.08))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }
}
