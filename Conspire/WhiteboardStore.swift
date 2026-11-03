//
//  WhiteboardStore.swift
//  Conspire
//

import Combine
import CoreGraphics
import AppKit
import SwiftUI
import Foundation
import SwiftData

/// Endpoint identifier for strings: a note, a whole stack, or a pin on an image.
///
/// A string never attaches to an image as a whole — it attaches to a pin, which
/// is a point on that image. So "connected to this part of the picture" is the
/// only kind of connection an image can have.
enum NodeID: Hashable, Codable {
    case note(UUID)
    case stack(UUID)
    case pin(UUID)
}

struct LinkID: Hashable, Codable {
    let rawValue: UUID
    init(_ id: UUID = UUID()) { self.rawValue = id }
}

struct Link: Identifiable, Hashable, Codable {
    var id: LinkID = LinkID()
    var from: NodeID
    var to: NodeID
    var colorIndex: Int // 0..2
    var label: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    func connects(_ x: NodeID, _ y: NodeID) -> Bool {
        (from == x && to == y) || (from == y && to == x)
    }

    /// True when either end is pinned to an image.
    ///
    /// Decides whether the string settles into place or tracks exactly. An
    /// image is a Core Animation layer with actions disabled, so it moves with
    /// no easing; a string eased over 200ms visibly comes unstuck from its pin
    /// while the picture is dragged, and catches up afterwards. Notes *do*
    /// settle, and their strings settle with them, so this is deliberately
    /// about pins rather than about whether a drag is happening.
    var touchesPin: Bool {
        if case .pin = from { return true }
        if case .pin = to { return true }
        return false
    }

    /// Direction-independent identity of the endpoint pair, for dedupe and fanning parallel links.
    var pairKey: String {
        let f = from.keyString
        let t = to.keyString
        return f <= t ? "\(f)|\(t)" : "\(t)|\(f)"
    }
}

extension NodeID {
    var keyString: String {
        switch self {
        case .note(let id): return "n:\(id.uuidString)"
        case .stack(let id): return "s:\(id.uuidString)"
        case .pin(let id): return "p:\(id.uuidString)"
        }
    }
}

struct LinkCurveGeometry: Equatable {
    var a: CGPoint
    var control: CGPoint
    var b: CGPoint
}

enum LinkVisibility: CaseIterable {
    case hidden, dimmed, full

    var symbolName: String {
        switch self {
        case .hidden: return "eye.slash"
        case .dimmed: return "eye"
        case .full: return "eye.fill"
        }
    }
}

/// Which tool the canvas is currently in — mutually exclusive.
///
/// `.hand` is the resting state and the default: every interaction works
/// except making new things, so a stray click can never leave a note behind.
/// The rest are tools you pick up. `.note` and `.string` still move notes and
/// reshape existing fields; `.field` puts the pencil in your hand, and a drag
/// anywhere on the canvas draws a zone instead.
enum PlacementMode: Sendable {
    case hand
    case note
    case string
    case field

    /// A one-shot tool hands itself back as soon as it has made something.
    /// Strings get drawn in runs, so the string tool stays where you put it.
    var returnsToHandAfterUse: Bool {
        switch self {
        case .note, .field: return true
        case .hand, .string: return false
        }
    }
}

/// One row in the flat canvas + carry render list.
struct NoteDrawEntry: Identifiable {
    let noteID: UUID
    let groupID: UUID
    let worldTopLeft: CGPoint
    let noteIndex: Int
    let totalInGroup: Int
    let isCarried: Bool
    /// Duplicate pile flying to placement while stamping (Option); not the user’s sustained carry.
    var isStampPlacementOverlay: Bool = false

    var id: UUID { noteID }
    var isTop: Bool { noteIndex == totalInGroup - 1 }
}

private struct UndoSnapshot {
    var board: [NoteGroup]
    var carried: NoteGroup?
    /// Note rows to remove when applying this snapshot (undo after duplicate / stamp).
    var deleteNoteIDsAfterApply: Set<UUID> = []
}

private struct DragSession {
    let undoBefore: UndoSnapshot
    let originGroupID: UUID
    let isTopOnly: Bool
    /// When true, `cancelDrag` deletes clone note IDs in the carry before restoring the board.
    let carriesDuplicateNotes: Bool
}

@MainActor
final class WhiteboardStore: ObservableObject {
    @Published var editingNoteID: UUID?
    /// When true, sidebar board-name `TextField` is active; canvas must not swallow Backspace/delete.
    @Published var isBoardListRenaming: Bool = false
    @Published var hoveredGroupID: UUID?
    /// The note whose inspector is showing. Notes were the only object on the
    /// canvas without a selection, which is why their controls had to live on
    /// the card itself.
    @Published var selectedNoteID: UUID?
    @Published private(set) var carriedGroup: NoteGroup?
    /// Option-stamp clones animating toward placement; originals stay in `carriedGroup`.
    @Published private(set) var stampPlacementOverlay: NoteGroup?
    @Published var canvasPan: CGSize = .zero
    @Published var canvasScale: CGFloat = 1.0
    /// True while the canvas is actively being panned or zoomed.
    ///
    /// Glass samples whatever is behind it, and while the canvas moves that is
    /// a new backdrop every frame — a cost nothing can cache, and worse under a
    /// pinch than a pan because the content is scaling rather than sliding. So
    /// the floating panels drop their blur for the duration of the gesture and
    /// take it back once the canvas settles. Nobody is studying a panel's blur
    /// while they are throwing the board around.
    @Published private(set) var isCanvasMoving: Bool = false
    private var canvasSettleTask: Task<Void, Never>?
    @Published var cursorInRoot: CGPoint = .zero
    @Published var noteColourPicked: Int = 0
    @Published var placementMode: PlacementMode = .hand
    @Published var isAnimatingCycle: Bool = false
    @Published var activeBoardID: UUID?
    @Published var activeBoardName: String = ""

    // MARK: - Strings (links)
    @Published var links: [LinkID: Link] = [:]
    @Published var stringColourPicked: Int = 0
    @Published var stringVisibility: LinkVisibility = .full
    @Published var linkDraftSource: NodeID? = nil
    @Published var linkDraftCursor: CGPoint? = nil
    @Published var selectedLinkID: LinkID? = nil
    @Published var hoveredLinkID: LinkID? = nil

    // MARK: - Fields (zones)
    @Published var fields: [Field] = []
    @Published var fieldColourPicked: Int = 0
    @Published var selectedFieldID: UUID?
    @Published var fieldReshapeMode: FieldReshapeMode = .clay
    @Published var fieldBrushRadius: CGFloat = WhiteboardStyle.fieldBrushDefault
    @Published var fieldJoinSoftness: CGFloat = WhiteboardStyle.fieldJoinDefault
    @Published var fieldTidyPasses: Int = WhiteboardStyle.fieldTidyDefault
    /// World-space points of the stroke being drawn, if any.
    @Published var fieldDraftStroke: FieldRing = []
    @Published var fieldDraftIsCarve: Bool = false
    /// Field the current stroke started inside — the one it will extend.
    @Published var fieldDraftHostID: UUID?
    /// Outline arc under the cursor, highlighted to show what a drag would move.
    @Published var fieldHoverEdge: FieldEdgeHover?
    /// Field membership, cached. Recomputing this inside view bodies cost ~3.4ms
    /// per frame, which is most of a 120Hz budget before anything is drawn.
    /// Rebuilt only when the fields or the notes actually move.
    @Published var noteFieldChips: [UUID: [FieldChip]] = [:]
    @Published var fieldNoteCounts: [UUID: Int] = [:]
    /// Groups riding along with a ⌘-drag of a field; applied in `noteDrawEntries`.
    @Published var fieldMoveGroupIDs: Set<UUID> = []
    @Published var fieldMoveOffset: CGSize = .zero
    var fieldGesture: FieldGesture?

    // MARK: - Images
    @Published var images: [ImageAsset] = []
    /// Decoded display assets, keyed by **resource** id rather than placement,
    /// so two boards showing the same picture share one decode and one texture.
    /// This dictionary *is* the cache: one decode per picture, filled on
    /// import, on load, and on a resample.
    @Published var imageContents: [UUID: CGImage] = [:]
    @Published var selectedImageID: UUID?
    @Published var hoveredImageID: UUID?
    var imageGesture: ImageGesture?
    var imageUndoBeforeGesture: ImageUndoState?

    // MARK: - Library
    /// The project the open board belongs to; resources are scoped to it.
    @Published var activeProjectID: UUID?
    @Published var imageResources: [ImageResource] = []
    @Published var textResources: [TextResource] = []
    /// Notes per text item, across the project. Cached: every note is a
    /// library item now, so this is read far too often to recount.
    @Published var textResourceUseCounts: [UUID: Int] = [:]
    /// Decoded 256px grid thumbnails, by resource id.
    @Published var imageThumbnails: [UUID: CGImage] = [:]
    /// Called after `locate` switches board, so the view can reload the rest of
    /// the board's state the way it does for a sidebar click.
    var onBoardSwitched: (() -> Void)?

    /// Pins: points on an image that strings attach to, by pin id.
    @Published var pins: [UUID: ImagePin] = [:]
    /// Pin created to start the current string draft, so abandoning the draft
    /// does not leave a pin behind.
    var linkDraftCreatedPinID: UUID?
    var pinGesture: PinGesture?
    /// Set while a pin is being dragged clear of its picture, so the overlay
    /// can show that letting go now would detach it.
    @Published var pinDragWillDetach: Bool = false

    @Published private(set) var actionLog: [String] = []

    weak var persistence: WhiteboardPersistenceService?
    weak var undoManager: UndoManager?

    private let minCanvasScale: CGFloat = 0.35
    private let maxCanvasScale: CGFloat = 3.0
    /// Sticky 100% zoom: enter when this close to 1.0 (99-101% band).
    private let snapEnterDelta: CGFloat = 0.01
    /// Leave sticky snap when scale moves past this distance from 1.0.
    private let snapExitDelta: CGFloat = 0.02
    /// Light haptic when scale changes by this much while not snapped.
    private let zoomTickStep: CGFloat = 0.05
    private var lastHapticTickScale: CGFloat = 1.0
    private var isSnappedTo1x = false
    /// Accumulates pinch intent while snapped so users can pass through 1.0 in one gesture.
    private var snapBypassScaleAccumulator: CGFloat?
    private let cycleAnimationDurationNs: UInt64 = 160_000_000
    private let carryPickPlaceAnimationNs: UInt64 = 200_000_000
    private let firstPickupLerpFrameCount = 12
    private let firstPickupLerpFrameNs: UInt64 = 16_666_667
    private let actionLogMaxEntries = 30
    /// When false, `carriedGroup.anchor` is driven by animations only (pickup / place), not live cursor.
    private var carryAnchorFollowsCursor = true
    private var firstPickupLerpTask: Task<Void, Never>?
    private var activeDragSession: DragSession?
    /// Forces the next `updateCursor` through even if the point has not moved.
    private var hasPendingCursorWork = true

    var activeGroups: [NoteGroupRender] { persistence?.activeGroups ?? [] }

    var activeNotesByID: [UUID: NoteRender] { persistence?.activeNotesByID ?? [:] }

    func attachUndoManager(_ manager: UndoManager?) {
        undoManager = manager
    }

    /// Board groups first (by z-order), then carried notes on top for hit-testing / draw order.
    var noteDrawEntries: [NoteDrawEntry] {
        var out: [NoteDrawEntry] = []
        for g in activeGroups {
            let ng = NoteGroup(id: g.id, anchor: g.anchor, zOrder: g.zOrder, noteIDs: g.noteIDs)
            // Live preview while a field carries its notes; committed in `endFieldGesture`.
            let carry = fieldMoveGroupIDs.contains(g.id) ? fieldMoveOffset : .zero
            for (i, nid) in g.noteIDs.enumerated() {
                var tl = BoardLayout.noteTopLeftWorld(group: ng, noteIndex: i)
                tl.x += carry.width
                tl.y += carry.height
                out.append(
                    NoteDrawEntry(
                        noteID: nid,
                        groupID: g.id,
                        worldTopLeft: tl,
                        noteIndex: i,
                        totalInGroup: g.noteIDs.count,
                        isCarried: false
                    )
                )
            }
        }
        if let c = carriedGroup {
            for (i, nid) in c.noteIDs.enumerated() {
                let tl = BoardLayout.noteTopLeftWorld(group: c, noteIndex: i)
                out.append(
                    NoteDrawEntry(
                        noteID: nid,
                        groupID: c.id,
                        worldTopLeft: tl,
                        noteIndex: i,
                        totalInGroup: c.noteIDs.count,
                        isCarried: true,
                        isStampPlacementOverlay: false
                    )
                )
            }
        }
        if let overlay = stampPlacementOverlay {
            for (i, nid) in overlay.noteIDs.enumerated() {
                let tl = BoardLayout.noteTopLeftWorld(group: overlay, noteIndex: i)
                out.append(
                    NoteDrawEntry(
                        noteID: nid,
                        groupID: overlay.id,
                        worldTopLeft: tl,
                        noteIndex: i,
                        totalInGroup: overlay.noteIDs.count,
                        isCarried: false,
                        isStampPlacementOverlay: true
                    )
                )
            }
        }
        return out
    }

    // MARK: - Cursor / hover

    func updateCursor(_ pointInRoot: CGPoint) {
        // Two sources report the same physical move (the AppKit monitor and the
        // root view's continuous hover); doing the work once is enough.
        if abs(pointInRoot.x - cursorInRoot.x) < 0.5,
           abs(pointInRoot.y - cursorInRoot.y) < 0.5,
           !hasPendingCursorWork {
            return
        }
        hasPendingCursorWork = false
        cursorInRoot = pointInRoot
        let world = rootToWorld(pointInRoot)
        // Hover radius is in world units; divide by scale so it feels constant on screen.
        let hovered = pickLink(atWorld: world, radius: 16 / max(canvasScale, 0.01))
        if hovered != hoveredLinkID { hoveredLinkID = hovered }
        updateFieldHover(atWorld: world)
        if var carry = carriedGroup, carryAnchorFollowsCursor {
            carry.anchor = (activeDragSession != nil) ? rootToWorld(pointInRoot) : rootToWorld(bottomCenterFollowRoot())
            carriedGroup = carry
        } else {
            hoveredGroupID = BoardLayout.hitGroup(world: world, groups: boardNoteGroups())
        }
    }

    /// Put the tools down. Nothing is destroyed and nothing is deselected —
    /// only the ability to create goes away.
    func enterHandMode() {
        placementMode = .hand
        cancelLinkDraft()
    }

    /// Called at the moment a tool has finished making something. The note and
    /// field tools return to the hand here; the string tool stays.
    func finishOneShotTool() {
        guard placementMode.returnsToHandAfterUse else { return }
        placementMode = .hand
    }

    /// Escape peels one layer at a time: abandon what is in progress, then let
    /// go of what is selected, then put the tool down. Returns false when there
    /// was nothing to dismiss, so the key can fall through to the responder
    /// chain (a focused text field, the window).
    func handleEscape() -> Bool {
        if editingNoteID != nil {
            stopEditing()
            return true
        }
        if fieldGesture != nil || !fieldDraftStroke.isEmpty {
            cancelFieldGesture()
            return true
        }
        if imageGesture != nil {
            cancelImageGesture()
            return true
        }
        if pinGesture != nil {
            cancelPinGesture()
            return true
        }
        if linkDraftSource != nil {
            cancelLinkDraft()
            return true
        }
        if selectedFieldID != nil || selectedLinkID != nil || selectedImageID != nil
            || selectedNoteID != nil {
            selectField(nil)
            selectLink(nil)
            selectImage(nil)
            selectedNoteID = nil
            return true
        }
        if placementMode != .hand {
            enterHandMode()
            return true
        }
        return false
    }

    func pickNoteColour(_ index: Int) {
        noteColourPicked = index
        placementMode = .note
        cancelLinkDraft()
    }

    func pickStringColour(_ index: Int) {
        stringColourPicked = index
        placementMode = .string
    }

    /// Picking a field colour puts the pencil in your hand.
    func pickFieldColour(_ index: Int) {
        fieldColourPicked = index
        if let id = selectedFieldID, let idx = fields.firstIndex(where: { $0.id == id }) {
            let before = fields
            fields[idx].colourIndex = index
            fields[idx].updatedAt = Date()
            persistField(fields[idx])
            rebuildFieldMembership()
            registerFieldUndo(before, actionName: "Recolour Field")
            return
        }
        placementMode = .field
        cancelLinkDraft()
    }

    // MARK: - Strings API
    func beginLink(from source: NodeID) {
        guard linkDraftSource == nil else { return }
        linkDraftSource = source
        linkDraftCursor = cursorInRoot
    }

    func updateLinkDraft(to rootPoint: CGPoint) {
        linkDraftCursor = rootPoint
    }

    func commitLink(to target: NodeID) {
        guard let src = linkDraftSource else { return }
        defer { cancelLinkDraft() }
        guard src != target else { return }
        let color = stringColourPicked
        if let existing = links.values.first(where: { $0.connects(src, target) && $0.colorIndex == color }) {
            selectLink(existing.id)
            appendActionLog("link already exists")
            return
        }
        let link = Link(from: src, to: target, colorIndex: color)
        links[link.id] = link
        saveLink(link)
        appendActionLog("link created")
    }

    func cancelLinkDraft() {
        linkDraftSource = nil
        linkDraftCursor = nil
        // A pin made only to start this string goes with it. On a successful
        // commit the pin now holds a link, so this leaves it alone.
        if let pinID = linkDraftCreatedPinID {
            linkDraftCreatedPinID = nil
            removePinIfOrphaned(pinID)
        }
    }

    func cycleStringVisibility() {
        switch stringVisibility {
        case .full: stringVisibility = .dimmed
        case .dimmed: stringVisibility = .hidden
        case .hidden: stringVisibility = .full
        }
    }

    /// Nearest link to a world-space point within `radius`, measured against the actual curve.
    func pickLink(atWorld point: CGPoint, radius: CGFloat = 14) -> LinkID? {
        var bestID: LinkID? = nil
        var bestDist = radius
        for link in links.values {
            guard let a = anchorPoint(for: link.from), let b = anchorPoint(for: link.to) else { continue }
            let control = controlPoint(for: link, a: a, b: b)
            let dist = distanceToCurve(point: point, a: a, control: control, b: b)
            if dist < bestDist {
                bestDist = dist
                bestID = link.id
            }
        }
        return bestID
    }

    private func distanceToCurve(point: CGPoint, a: CGPoint, control: CGPoint, b: CGPoint, samples: Int = 24) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let mt = 1 - t
            let x = mt * mt * a.x + 2 * mt * t * control.x + t * t * b.x
            let y = mt * mt * a.y + 2 * mt * t * control.y + t * t * b.y
            best = min(best, hypot(point.x - x, point.y - y))
        }
        return best
    }

    func selectLink(_ id: LinkID?) {
        selectedLinkID = id
        if id != nil { selectedNoteID = nil }
    }

    /// One selection at a time, so Delete and Escape always have one target.
    func selectNote(_ id: UUID?) {
        selectedNoteID = id
        if id != nil {
            selectedFieldID = nil
            selectedImageID = nil
            selectedLinkID = nil
        }
    }

    func setSelectedNoteColour(_ index: Int) {
        guard let id = selectedNoteID else { return }
        persistence?.setNoteColour(noteID: id, colour: index)
    }

    func setSelectedNoteStamp(_ symbol: String?) {
        guard let id = selectedNoteID else { return }
        persistence?.setNoteStamp(noteID: id, stamp: symbol)
    }

    func setSelectedLinkColor(index: Int) {
        guard let id = selectedLinkID, var link = links[id] else { return }
        link.colorIndex = index
        link.updatedAt = Date()
        links[id] = link
        updateLink(link)
    }

    func setSelectedLinkLabel(_ label: String) {
        guard let id = selectedLinkID, var link = links[id] else { return }
        link.label = label.isEmpty ? nil : label
        link.updatedAt = Date()
        links[id] = link
        updateLink(link)
    }

    func deleteSelectedLink() {
        guard let id = selectedLinkID else { return }
        removeLink(id)
    }

    /// Deletes note rows and any strings attached to them, so links can't outlive their endpoints.
    private func deleteNotes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        persistence?.deleteNotes(ids)
        let orphaned = links.values.filter { link in
            ids.contains(endpointID(link.from)) || ids.contains(endpointID(link.to))
        }
        for link in orphaned {
            removeLink(link.id)
        }
    }

    private func endpointID(_ node: NodeID) -> UUID {
        switch node {
        case .note(let id): return id
        case .stack(let id): return id
        case .pin(let id): return id
        }
    }

    func removeLink(_ id: LinkID) {
        let removed = links[id]
        links.removeValue(forKey: id)
        deleteLink(id: id)
        if selectedLinkID == id { selectedLinkID = nil }
        if hoveredLinkID == id { hoveredLinkID = nil }
        // A pin exists only to hold strings, so the last one leaving takes it.
        if let removed {
            for node in [removed.from, removed.to] {
                if case .pin(let pinID) = node { removePinIfOrphaned(pinID) }
            }
        }
        appendActionLog("link deleted")
    }

    /// Reconciles persisted links with `links` — needed after an undo replaces
    /// the dictionary wholesale. Lives here because the insert and delete
    /// helpers it uses are private to this file.
    func reconcileLinkEntities() {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        let predicate = #Predicate<LinkEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<LinkEntity>(predicate: predicate))) ?? []
        var kept = Set<UUID>()
        for entity in entities {
            if links[LinkID(entity.id)] == nil {
                context.delete(entity)
            } else {
                kept.insert(entity.id)
            }
        }
        for link in links.values where !kept.contains(link.id.rawValue) {
            saveLink(link)
        }
        try? context.save()
    }

    func loadLinksForActiveBoard() {
        guard let context = persistence?.context, let boardID = activeBoardID else {
            links = [:]
            return
        }
        let predicate = #Predicate<LinkEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<LinkEntity>(predicate: predicate))) ?? []
        var loaded: [LinkID: Link] = [:]
        for entity in entities {
            let link = entity.toLink()
            loaded[link.id] = link
        }
        links = loaded
    }

    private func saveLink(_ link: Link) {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        context.insert(LinkEntity(boardID: boardID, link: link))
        try? context.save()
    }

    private func updateLink(_ link: Link) {
        guard let context = persistence?.context else { return }
        let targetID = link.id.rawValue
        let predicate = #Predicate<LinkEntity> { $0.id == targetID }
        if let entity = try? context.fetch(FetchDescriptor<LinkEntity>(predicate: predicate)).first {
            entity.colorIndex = link.colorIndex
            entity.label = link.label
            entity.updatedAt = link.updatedAt
            try? context.save()
        }
    }

    private func deleteLink(id: LinkID) {
        guard let context = persistence?.context else { return }
        let targetID = id.rawValue
        let predicate = #Predicate<LinkEntity> { $0.id == targetID }
        if let entity = try? context.fetch(FetchDescriptor<LinkEntity>(predicate: predicate)).first {
            context.delete(entity)
            try? context.save()
        }
    }

    // MARK: - Editing

    func startEditing(note id: UUID) {
        editingNoteID = id
    }

    func stopEditing() {
        editingNoteID = nil
    }

    func clearTransientStateForBoardSwitch() {
        cancelDrag()
        cancelFirstPickupLerp()
        discardStampPlacementOverlayCleaningOrphans()
        carriedGroup = nil
        hoveredGroupID = nil
        editingNoteID = nil
        isAnimatingCycle = false
        actionLog.removeAll()
        carryAnchorFollowsCursor = true

        // Clear link draft; keep existing links for the active board for now
        cancelLinkDraft()
        cancelFieldGesture()
        selectedFieldID = nil
        fieldHoverEdge = nil
    }

    func appendActionLog(_ line: String) {
        actionLog.append(line)
        if actionLog.count > actionLogMaxEntries {
            actionLog.removeFirst(actionLog.count - actionLogMaxEntries)
        }
    }

    func handleBackgroundPrimaryTap(atRootPoint rootPoint: CGPoint) {
        handleBackgroundPrimaryTap(atRootPoint: rootPoint, modifiers: InputModifiers.current())
    }

    func handleBackgroundPrimaryTap(atRootPoint rootPoint: CGPoint, modifiers: InputModifiers) {
        let world = rootToWorld(rootPoint)

        // Holding notes trumps every creation interaction: the click always means "place".
        if carriedGroup != nil {
            stopEditing()
            placeCarriedAt(world: world, modifiers: modifiers)
            return
        }

        if let hitLink = pickLink(atWorld: world) {
            selectLink(hitLink)
            return
        }
        // Clicking empty canvas puts everything down.
        selectLink(nil)
        selectField(nil)
        selectImage(nil)
        selectedNoteID = nil

        if placementMode == .string {
            cancelLinkDraft()
            return
        }
        let wasEditing = editingNoteID != nil
        stopEditing()

        if wasEditing { return }
        // Only the note tool creates from the canvas; the hand and the pencil
        // have already done their work above (deselecting, ending editing).
        guard placementMode == .note else { return }
        createNoteAndEdit(centeredAt: world)
    }

    /// Top note of a board group tapped while carrying → merge onto that group (unless Command forces new stack).
    func handlePrimaryTapOnBoardGroup(groupID: UUID) {
        handlePrimaryTapOnBoardGroup(groupID: groupID, modifiers: InputModifiers.current())
    }

    /// Left-click a board stack while not carrying: add a new note on top and start editing it.
    func createNoteOnTopOfBoardStack(groupID: UUID) {
        guard placementMode == .note else { return }
        guard activeDragSession == nil else { return }
        guard carriedGroup == nil else { return }
        guard activeGroups.contains(where: { $0.id == groupID }) else { return }
        stopEditing()
        if let noteID = persistence?.appendNoteOnTopOfGroup(groupID: groupID, colour: noteColourPicked) {
            editingNoteID = noteID
            appendActionLog("new note on stack \(groupID.uuidString.prefix(8))…")
            finishOneShotTool()
        }
    }

    func handlePrimaryTapOnBoardGroup(groupID: UUID, modifiers: InputModifiers) {
        guard let baseCarry = carriedGroup else { return }
        if modifiers.command {
            placeCarriedAt(world: rootToWorld(cursorInRoot), modifiers: modifiers)
            return
        }
        let undoBefore = snapshot()
        var placementCarry = baseCarry
        var stampUndoIds = Set<UUID>()
        if modifiers.option {
            guard let stamp = cloneCarryForStamp(baseCarry) else { return }
            placementCarry = stamp
            stampUndoIds = Set(stamp.noteIDs)
        }
        placeCarriedOntoBoardGroupAnimated(
            targetID: groupID,
            modifiers: modifiers,
            undoBefore: undoBefore,
            placementCarry: placementCarry,
            stampUndoIds: stampUndoIds
        )
    }

    func updateNoteText(note id: UUID, text: String) {
        persistence?.updateNoteText(noteID: id, text: text)
    }

    // MARK: - Pan / Zoom

    func applyPan(_ translation: CGSize) {
        canvasPan = CGSize(
            width: canvasPan.width + translation.width,
            height: canvasPan.height + translation.height
        )
        noteCanvasMovement()
    }

    /// Marks the canvas as moving, and schedules the moment it stops.
    ///
    /// Scroll and pinch arrive as a stream of discrete events with no end, so
    /// "settled" has to be inferred from a gap between them.
    private func noteCanvasMovement() {
        if !isCanvasMoving { isCanvasMoving = true }
        canvasSettleTask?.cancel()
        canvasSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.isCanvasMoving = false
            }
            self.canvasSettleTask = nil
        }
    }

    func applyZoom(magnification: CGFloat, atRootPoint rootPoint: CGPoint) {
        noteCanvasMovement()
        let oldScale = max(canvasScale, 0.0001)
        let scaleBase = max(isSnappedTo1x ? (snapBypassScaleAccumulator ?? oldScale) : oldScale, 0.0001)
        let raw = scaleBase * (1 + magnification)
        let clamped = min(max(raw, minCanvasScale), maxCanvasScale)

        var newScale = clamped

        if isSnappedTo1x {
            snapBypassScaleAccumulator = clamped
            if abs(clamped - 1.0) > snapExitDelta {
                isSnappedTo1x = false
                newScale = clamped
                snapBypassScaleAccumulator = nil
            } else {
                newScale = 1.0
            }
        } else if abs(clamped - 1.0) <= snapEnterDelta && abs(oldScale - 1.0) > snapEnterDelta {
            isSnappedTo1x = true
            snapBypassScaleAccumulator = clamped
            newScale = 1.0
            HapticEngine.strong()
        } else {
            snapBypassScaleAccumulator = nil
        }

        guard newScale != oldScale else { return }

        let worldX = (rootPoint.x - canvasPan.width) / oldScale
        let worldY = (rootPoint.y - canvasPan.height) / oldScale

        canvasScale = newScale
        canvasPan = CGSize(
            width: rootPoint.x - worldX * newScale,
            height: rootPoint.y - worldY * newScale
        )

        if abs(newScale - lastHapticTickScale) >= zoomTickStep && !isSnappedTo1x {
            HapticEngine.light()
            lastHapticTickScale = newScale
        }
        if isSnappedTo1x {
            lastHapticTickScale = newScale
        }
    }

    /// Animate scale to 1.0 with the viewport center as the zoom anchor.
    func animateZoomReset(viewportSize: CGSize) {
        let centerRoot = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let oldScale = max(canvasScale, 0.0001)
        let worldX = (centerRoot.x - canvasPan.width) / oldScale
        let worldY = (centerRoot.y - canvasPan.height) / oldScale

        let targetScale: CGFloat = 1.0
        let targetPan = CGSize(
            width: centerRoot.x - worldX * targetScale,
            height: centerRoot.y - worldY * targetScale
        )

        withAnimation(.easeInOut(duration: 0.25)) {
            canvasScale = targetScale
            canvasPan = targetPan
        }
        isSnappedTo1x = true
        snapBypassScaleAccumulator = nil
        lastHapticTickScale = targetScale
        HapticEngine.strong()
    }

    /// Union world rect of board groups and any carried stack; `.null` when empty.
    var contentWorldBounds: CGRect {
        var r: CGRect = .null
        for g in activeGroups {
            let ng = NoteGroup(id: g.id, anchor: g.anchor, zOrder: g.zOrder, noteIDs: g.noteIDs)
            let gr = BoardLayout.groupUnionWorldRect(ng)
            r = r.isNull ? gr : r.union(gr)
        }
        if let c = carriedGroup {
            let gr = BoardLayout.carriedUnionWorldRect(c)
            r = r.isNull ? gr : r.union(gr)
        }
        return r
    }

    func contentCenterWorld() -> CGPoint? {
        let r = contentWorldBounds
        return r.isNull ? nil : CGPoint(x: r.midX, y: r.midY)
    }

    /// Whether the content-bounds center lies inside the viewport (root coordinates).
    func isContentCenterOnScreen(viewportSize: CGSize) -> Bool {
        guard let world = contentCenterWorld() else { return false }
        let p = worldToRoot(world)
        return CGRect(origin: .zero, size: viewportSize).contains(p)
    }

    /// Bearing in radians from viewport center to content center; 0 = up, clockwise positive.
    func bearingToContentCenter(viewportSize: CGSize) -> CGFloat? {
        guard let world = contentCenterWorld() else { return nil }
        let p = worldToRoot(world)
        let cx = viewportSize.width / 2
        let cy = viewportSize.height / 2
        let dx = p.x - cx
        let dy = p.y - cy
        if abs(dx) < 0.5 && abs(dy) < 0.5 { return 0 }
        return atan2(dx, -dy)
    }

    /// Fit all content in the viewport with margin and animate pan + scale.
    func animateCenterToContent(viewportSize: CGSize) {
        let r = contentWorldBounds
        guard !r.isNull else { return }

        let margin: CGFloat = 80
        let availW = max(viewportSize.width - margin * 2, 1)
        let availH = max(viewportSize.height - margin * 2, 1)
        let fitScale = min(availW / max(r.width, 1), availH / max(r.height, 1))
        let targetScale = min(max(fitScale, minCanvasScale), maxCanvasScale)

        let centerRoot = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let center = CGPoint(x: r.midX, y: r.midY)
        let targetPan = CGSize(
            width: centerRoot.x - center.x * targetScale,
            height: centerRoot.y - center.y * targetScale
        )

        withAnimation(.easeInOut(duration: 0.3)) {
            canvasScale = targetScale
            canvasPan = targetPan
        }
        isSnappedTo1x = false
        snapBypassScaleAccumulator = nil
        lastHapticTickScale = targetScale
        HapticEngine.strong()
    }

    // MARK: - Stack cycling

    func handleCycleForward() {
        guard !isAnimatingCycle else { return }
        guard editingNoteID == nil else { return }
        isAnimatingCycle = true

        withAnimation(.easeInOut(duration: 0.16)) {
            if var carry = carriedGroup, activeDragSession == nil {
                carry = GroupLogic.cycleTopToBottom(carry)
                carriedGroup = carry
            } else if let gid = hoveredGroupID {
                cycleBoardGroup(id: gid, forward: true)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: cycleAnimationDurationNs)
            isAnimatingCycle = false
        }
    }

    func handleCycleBackward() {
        guard !isAnimatingCycle else { return }
        guard editingNoteID == nil else { return }
        isAnimatingCycle = true

        withAnimation(.easeInOut(duration: 0.16)) {
            if var carry = carriedGroup, activeDragSession == nil {
                carry = GroupLogic.cycleBottomToTop(carry)
                carriedGroup = carry
            } else if let gid = hoveredGroupID {
                cycleBoardGroup(id: gid, forward: false)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: cycleAnimationDurationNs)
            isAnimatingCycle = false
        }
    }

    // MARK: - Pick up / place

    func pickUp(groupID: UUID) {
        pickUp(groupID: groupID, modifiers: InputModifiers.current())
    }

    func pickUp(groupID: UUID, modifiers: InputModifiers) {
        cancelLinkDraft()
        discardStampPlacementOverlayCleaningOrphans()
        let undoBefore = snapshot()
        guard let pickedRender = activeGroups.first(where: { $0.id == groupID }) else { return }
        let picked = NoteGroup(
            id: pickedRender.id,
            anchor: pickedRender.anchor,
            zOrder: pickedRender.zOrder,
            noteIDs: pickedRender.noteIDs
        )
        let priorCarried = carriedGroup
        let boardSnap = boardNoteGroups()

        if modifiers.option {
            let pickedIDs: [UUID] = {
                if modifiers.shift, pickedRender.noteIDs.count > 1 {
                    return [pickedRender.noteIDs.last!]
                }
                return pickedRender.noteIDs
            }()
            let dupIDs = persistence?.duplicateNotes(sourceIDs: pickedIDs) ?? []
            guard !dupIDs.isEmpty else { return }
            let mergedNoteIDs = (priorCarried?.noteIDs ?? []) + dupIDs
            let dupCarry = NoteGroup(
                id: UUID(),
                anchor: pickedRender.anchor,
                zOrder: pickedRender.zOrder,
                noteIDs: mergedNoteIDs
            )
            hoveredGroupID = nil

            let fullGroupForLayout = NoteGroup(
                id: pickedRender.id,
                anchor: pickedRender.anchor,
                zOrder: pickedRender.zOrder,
                noteIDs: pickedRender.noteIDs
            )
            let initialWorld: CGPoint = {
                if modifiers.shift, pickedRender.noteIDs.count > 1 {
                    let topIdx = pickedRender.noteIDs.count - 1
                    return BoardLayout.noteCenterWorld(group: fullGroupForLayout, noteIndex: topIdx)
                }
                return picked.anchor
            }()

            if priorCarried == nil {
                cancelFirstPickupLerp()
                var c = dupCarry
                c.anchor = initialWorld
                carriedGroup = c
                carryAnchorFollowsCursor = false
                let fromWorld = initialWorld
                firstPickupLerpTask = Task { @MainActor in
                    let n = firstPickupLerpFrameCount
                    for i in 1...n {
                        try? await Task.sleep(nanoseconds: firstPickupLerpFrameNs)
                        guard !Task.isCancelled, carriedGroup != nil else { return }
                        let t = Double(i) / Double(n)
                        let u = 1 - pow(1 - t, 3)
                        let target = rootToWorld(bottomCenterFollowRoot())
                        if var g = carriedGroup {
                            g.anchor = CGPoint(
                                x: fromWorld.x + (target.x - fromWorld.x) * u,
                                y: fromWorld.y + (target.y - fromWorld.y) * u
                            )
                            carriedGroup = g
                        }
                    }
                    guard !Task.isCancelled else { return }
                    carryAnchorFollowsCursor = true
                    if var g = carriedGroup {
                        g.anchor = rootToWorld(bottomCenterFollowRoot())
                        carriedGroup = g
                    }
                }
            } else {
                cancelFirstPickupLerp()
                var c = dupCarry
                c.anchor = priorCarried!.anchor
                carriedGroup = c
                carryAnchorFollowsCursor = true
            }
            var restoreState = undoBefore
            restoreState.deleteNoteIDsAfterApply = Set(dupIDs)
            registerUndoRedoRestore(restoreState, actionName: "Duplicate Notes")
            appendActionLog("option pickUp duplicate (\(dupIDs.count) notes)")
            return
        }

        let result: (remaining: [NoteGroup], carried: NoteGroup)?
        if modifiers.shift,
           let topOnly = GroupLogic.pickUpTopNote(
               pickedGroupID: groupID,
               from: boardSnap,
               into: priorCarried
           ) {
            result = topOnly
        } else {
            result = GroupLogic.pickUp(
                pickedGroupID: groupID,
                from: boardSnap,
                into: priorCarried
            )
        }
        guard let result else { return }

        persistence?.replaceBoardGroups(result.remaining)
        hoveredGroupID = nil

        let fullGroupForLayout = NoteGroup(
            id: pickedRender.id,
            anchor: pickedRender.anchor,
            zOrder: pickedRender.zOrder,
            noteIDs: pickedRender.noteIDs
        )
        let initialWorld: CGPoint = {
            if modifiers.shift, pickedRender.noteIDs.count > 1 {
                let topIdx = pickedRender.noteIDs.count - 1
                return BoardLayout.noteCenterWorld(group: fullGroupForLayout, noteIndex: topIdx)
            }
            return picked.anchor
        }()

        if priorCarried == nil {
            cancelFirstPickupLerp()
            var c = result.carried
            c.anchor = initialWorld
            carriedGroup = c
            carryAnchorFollowsCursor = false
            let fromWorld = initialWorld
            firstPickupLerpTask = Task { @MainActor in
                let n = firstPickupLerpFrameCount
                for i in 1...n {
                    try? await Task.sleep(nanoseconds: firstPickupLerpFrameNs)
                    guard !Task.isCancelled, carriedGroup != nil else { return }
                    let t = Double(i) / Double(n)
                    let u = 1 - pow(1 - t, 3)
                    let target = rootToWorld(bottomCenterFollowRoot())
                    if var g = carriedGroup {
                        g.anchor = CGPoint(
                            x: fromWorld.x + (target.x - fromWorld.x) * u,
                            y: fromWorld.y + (target.y - fromWorld.y) * u
                        )
                        carriedGroup = g
                    }
                }
                guard !Task.isCancelled else { return }
                carryAnchorFollowsCursor = true
                if var g = carriedGroup {
                    g.anchor = rootToWorld(bottomCenterFollowRoot())
                    carriedGroup = g
                }
            }
        } else {
            cancelFirstPickupLerp()
            var c = result.carried
            c.anchor = priorCarried!.anchor
            carriedGroup = c
            carryAnchorFollowsCursor = true
        }
        registerUndoRedoRestore(undoBefore, actionName: "Pick Up Notes")
        appendActionLog("pickUp group \(groupID.uuidString.prefix(8))… → carry \(result.carried.noteIDs.count) notes")
    }

    func handleRightMouseDown(atRootPoint rootPoint: CGPoint) {
        handleRightMouseDown(atRootPoint: rootPoint, modifiers: InputModifiers.current())
    }

    func handleRightMouseDown(atRootPoint rootPoint: CGPoint, modifiers: InputModifiers) {
        cursorInRoot = rootPoint
        if carriedGroup != nil {
            let rootCarry = carriedGroupUnionInRoot()
            if rootCarry.contains(rootPoint) { return }
        }
        let world = rootToWorld(rootPoint)
        guard let gid = BoardLayout.hitGroup(world: world, groups: boardNoteGroups()) else { return }
        pickUp(groupID: gid, modifiers: modifiers)
    }

    func handleDeleteHandShortcut() {
        guard editingNoteID == nil else { return }
        if activeDragSession != nil {
            cancelDrag()
            return
        }
        discardStampPlacementOverlayCleaningOrphans()
        guard let carry = carriedGroup else { return }
        cancelFirstPickupLerp()
        let ids = Set(carry.noteIDs)
        deleteNotes(ids)
        carriedGroup = nil
        carryAnchorFollowsCursor = true
        appendActionLog("delete carried notes (\(ids.count))")
    }

    /// Trash affordance on a board note. Whole stacks are deleted by picking them up and hitting Backspace.
    func deleteNote(_ noteID: UUID) {
        guard activeDragSession == nil else { return }
        guard carriedGroup == nil else { return }
        guard editingNoteID == nil else { return }

        deleteNotes([noteID])
        appendActionLog("delete note \(noteID.uuidString.prefix(8))…")
    }

    // MARK: - Dragging notes on the board

    @discardableResult
    func beginDrag(groupID: UUID, atRootPoint: CGPoint, modifiers: InputModifiers) -> Bool {
        guard editingNoteID == nil else { return false }
        if activeDragSession != nil {
            cancelDrag()
        }
        guard carriedGroup == nil else { return false }

        cancelLinkDraft()
        cancelFirstPickupLerp()
        let undoBefore = snapshot()
        guard let pickedRender = activeGroups.first(where: { $0.id == groupID }) else { return false }
        let boardSnap = boardNoteGroups()

        if modifiers.option {
            let pickedIDs: [UUID] = {
                if modifiers.shift, pickedRender.noteIDs.count > 1 {
                    return [pickedRender.noteIDs.last!]
                }
                return pickedRender.noteIDs
            }()
            let dupIDs = persistence?.duplicateNotes(sourceIDs: pickedIDs) ?? []
            guard !dupIDs.isEmpty else { return false }
            hoveredGroupID = nil
            cursorInRoot = atRootPoint
            carryAnchorFollowsCursor = true
            let carry = NoteGroup(
                id: UUID(),
                anchor: rootToWorld(atRootPoint),
                zOrder: pickedRender.zOrder,
                noteIDs: dupIDs
            )
            carriedGroup = carry
            let isTopOnly = modifiers.shift && pickedRender.noteIDs.count > 1
            activeDragSession = DragSession(
                undoBefore: undoBefore,
                originGroupID: groupID,
                isTopOnly: isTopOnly,
                carriesDuplicateNotes: true
            )
            appendActionLog("option drag begin duplicate (\(dupIDs.count) notes)")
            return true
        }

        let result: (remaining: [NoteGroup], carried: NoteGroup)?
        if modifiers.shift,
           let topOnly = GroupLogic.pickUpTopNote(
               pickedGroupID: groupID,
               from: boardSnap,
               into: nil
           ) {
            result = topOnly
        } else {
            result = GroupLogic.pickUp(pickedGroupID: groupID, from: boardSnap, into: nil)
        }
        guard let result else { return false }

        persistence?.replaceBoardGroups(result.remaining)
        hoveredGroupID = nil

        cursorInRoot = atRootPoint
        carryAnchorFollowsCursor = true
        var c = result.carried
        c.anchor = rootToWorld(atRootPoint)
        carriedGroup = c

        let isTopOnly = modifiers.shift && pickedRender.noteIDs.count > 1
        activeDragSession = DragSession(
            undoBefore: undoBefore,
            originGroupID: groupID,
            isTopOnly: isTopOnly,
            carriesDuplicateNotes: false
        )
        appendActionLog("drag begin group \(groupID.uuidString.prefix(8))… (\(c.noteIDs.count) notes)")
        return true
    }

    func updateDrag(atRootPoint: CGPoint) {
        updateCursor(atRootPoint)
    }

    func endDrag(atRootPoint: CGPoint) {
        guard let session = activeDragSession, let carry = carriedGroup else {
            activeDragSession = nil
            return
        }
        cursorInRoot = atRootPoint
        let world = rootToWorld(atRootPoint)
        let targetID = BoardLayout.hitGroup(world: world, groups: boardNoteGroups())
        let newBoard = GroupLogic.placeCarried(
            carry,
            placeBottomCenterWorld: world,
            onto: targetID,
            in: boardNoteGroups()
        )
        persistence?.replaceBoardGroups(newBoard)
        carriedGroup = nil
        activeDragSession = nil
        carryAnchorFollowsCursor = true
        var moveUndo = session.undoBefore
        if session.carriesDuplicateNotes {
            moveUndo.deleteNoteIDsAfterApply = Set(carry.noteIDs)
        }
        registerUndoRedoRestore(moveUndo, actionName: "Move Notes")
        if let tid = targetID {
            appendActionLog("drag end → merge onto \(tid.uuidString.prefix(8))…")
        } else {
            appendActionLog("drag end → relocate to (\(Int(world.x)),\(Int(world.y)))")
        }
    }

    func cancelDrag() {
        guard let session = activeDragSession else { return }
        activeDragSession = nil
        cancelFirstPickupLerp()
        if session.carriesDuplicateNotes, let carry = carriedGroup {
            deleteNotes(Set(carry.noteIDs))
        }
        persistence?.replaceBoardGroups(session.undoBefore.board)
        carriedGroup = session.undoBefore.carried
        carryAnchorFollowsCursor = true
        if var g = carriedGroup {
            g.anchor = rootToWorld(bottomCenterFollowRoot())
            carriedGroup = g
        }
        let world = rootToWorld(cursorInRoot)
        hoveredGroupID = BoardLayout.hitGroup(world: world, groups: boardNoteGroups())
    }

    // MARK: - Geometry

    /// The pan to draw with, rounded to whole device pixels.
    ///
    /// `canvasPan` accumulates fractional scroll deltas, so without this every
    /// frame lands the whole canvas on a different sub-pixel phase: nothing can
    /// reuse a rasterised surface and text re-renders each frame. Rounding only
    /// the rendered value keeps the accumulator exact, so panning never drifts.
    var pixelSnappedPan: CGSize {
        let density = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        return CGSize(
            width: (canvasPan.width * density).rounded() / density,
            height: (canvasPan.height * density).rounded() / density
        )
    }

    /// World point at the middle of the viewport — where something arrives
    /// when it was not dropped anywhere in particular.
    func viewportCenterWorld(viewportSize: CGSize) -> CGPoint {
        rootToWorld(CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
    }

    func rootToWorld(_ rootPoint: CGPoint) -> CGPoint {
        let safeScale = max(canvasScale, 0.0001)
        return CGPoint(
            x: (rootPoint.x - canvasPan.width) / safeScale,
            y: (rootPoint.y - canvasPan.height) / safeScale
        )
    }

    // MARK: - Private

    private func snapshot() -> UndoSnapshot {
        UndoSnapshot(board: boardNoteGroups(), carried: carriedGroup, deleteNoteIDsAfterApply: [])
    }

    private func applyUndoSnapshot(_ s: UndoSnapshot) {
        activeDragSession = nil
        cancelFirstPickupLerp()
        persistence?.replaceBoardGroups(s.board)
        carriedGroup = s.carried
        carryAnchorFollowsCursor = true
        if !s.deleteNoteIDsAfterApply.isEmpty {
            deleteNotes(s.deleteNoteIDsAfterApply)
        }
        if var g = carriedGroup {
            g.anchor = rootToWorld(bottomCenterFollowRoot())
            carriedGroup = g
        }
    }

    /// Registers an undo (and nested redo) that restores `stateToRestore`.
    private func registerUndoRedoRestore(_ stateToRestore: UndoSnapshot, actionName: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            let beforeThisUndo = target.snapshot()
            target.applyUndoSnapshot(stateToRestore)
            target.registerUndoRedoRestore(beforeThisUndo, actionName: actionName)
        }
        um.setActionName(actionName)
    }

    private func cancelFirstPickupLerp() {
        firstPickupLerpTask?.cancel()
        firstPickupLerpTask = nil
    }

    private func discardStampPlacementOverlayCleaningOrphans() {
        guard let overlay = stampPlacementOverlay else { return }
        deleteNotes(Set(overlay.noteIDs))
        stampPlacementOverlay = nil
    }

    private func boardNoteGroups() -> [NoteGroup] {
        activeGroups.map {
            NoteGroup(id: $0.id, anchor: $0.anchor, zOrder: $0.zOrder, noteIDs: $0.noteIDs)
        }
    }

    private func bottomCenterFollowRoot() -> CGPoint {
        CGPoint(
            x: cursorInRoot.x + WhiteboardStyle.handFollowOffset.width,
            y: cursorInRoot.y + WhiteboardStyle.handFollowOffset.height
        )
    }

    private func carriedGroupUnionInRoot() -> CGRect {
        guard let carry = carriedGroup else { return .null }
        let w = BoardLayout.carriedUnionWorldRect(carry)
        let tl = worldToRoot(CGPoint(x: w.minX, y: w.minY))
        let br = worldToRoot(CGPoint(x: w.maxX, y: w.maxY))
        return CGRect(x: min(tl.x, br.x), y: min(tl.y, br.y), width: abs(br.x - tl.x), height: abs(br.y - tl.y))
    }

    private func worldToRoot(_ worldPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: worldPoint.x * canvasScale + canvasPan.width,
            y: worldPoint.y * canvasScale + canvasPan.height
        )
    }

    /// Duplicate every note in `carry` for a stamp placement; returns a new in-hand group with fresh IDs.
    private func cloneCarryForStamp(_ carry: NoteGroup) -> NoteGroup? {
        guard let ids = persistence?.duplicateNotes(sourceIDs: carry.noteIDs), !ids.isEmpty else { return nil }
        return NoteGroup(id: UUID(), anchor: carry.anchor, zOrder: carry.zOrder, noteIDs: ids)
    }

    private func registerPlaceUndo(_ undoBefore: UndoSnapshot, stampIds: Set<UUID>, actionName: String) {
        var u = undoBefore
        u.deleteNoteIDsAfterApply = stampIds
        registerUndoRedoRestore(u, actionName: actionName)
    }

    private func placeCarriedAt(world: CGPoint, modifiers: InputModifiers) {
        guard let baseCarry = carriedGroup else { return }
        discardStampPlacementOverlayCleaningOrphans()

        let undoBefore = snapshot()
        cancelFirstPickupLerp()

        var placementCarry = baseCarry
        var stampUndoIds = Set<UUID>()
        if modifiers.option {
            guard let stamp = cloneCarryForStamp(baseCarry) else { return }
            placementCarry = stamp
            stampUndoIds = Set(stamp.noteIDs)
        }

        let target: UUID? = {
            if modifiers.command { return nil }
            return BoardLayout.hitGroup(world: world, groups: boardNoteGroups())
        }()

        if modifiers.shift, placementCarry.noteIDs.count > 1 {
            if !modifiers.command,
               let tid = target,
               activeGroups.contains(where: { $0.id == tid }),
               let targetRender = activeGroups.first(where: { $0.id == tid }) {
                let mergedPreview = NoteGroup(
                    id: targetRender.id,
                    anchor: targetRender.anchor,
                    zOrder: targetRender.zOrder,
                    noteIDs: targetRender.noteIDs + [placementCarry.noteIDs.last!]
                )
                let placePoint = BoardLayout.noteCenterWorld(
                    group: mergedPreview,
                    noteIndex: mergedPreview.noteIDs.count - 1
                )
                if let res = GroupLogic.placeCarriedTopOnly(
                    placementCarry,
                    placeBottomCenterWorld: placePoint,
                    onto: tid,
                    in: boardNoteGroups()
                ) {
                    persistence?.replaceBoardGroups(res.board)
                    if stampUndoIds.isEmpty {
                        carriedGroup = res.remainingCarry
                        carryAnchorFollowsCursor = true
                        if var g = carriedGroup {
                            g.anchor = rootToWorld(bottomCenterFollowRoot())
                            carriedGroup = g
                        }
                    } else if let rest = res.remainingCarry {
                        deleteNotes(Set(rest.noteIDs))
                    }
                    registerPlaceUndo(undoBefore, stampIds: stampUndoIds, actionName: "Place Notes")
                    appendActionLog("shift place top (merge)")
                    return
                }
            }
            if let res = GroupLogic.placeCarriedTopOnly(
                placementCarry,
                placeBottomCenterWorld: world,
                onto: nil,
                in: boardNoteGroups()
            ) {
                persistence?.replaceBoardGroups(res.board)
                if stampUndoIds.isEmpty {
                    carriedGroup = res.remainingCarry
                    carryAnchorFollowsCursor = true
                    if var g = carriedGroup {
                        g.anchor = rootToWorld(bottomCenterFollowRoot())
                        carriedGroup = g
                    }
                } else if let rest = res.remainingCarry {
                    deleteNotes(Set(rest.noteIDs))
                }
                registerPlaceUndo(undoBefore, stampIds: stampUndoIds, actionName: "Place Notes")
                appendActionLog("shift place top (new stack)")
                return
            }
        }

        if let tid = target, activeGroups.contains(where: { $0.id == tid }) {
            placeCarriedOntoBoardGroupAnimated(
                targetID: tid,
                modifiers: modifiers,
                undoBefore: undoBefore,
                placementCarry: placementCarry,
                stampUndoIds: stampUndoIds
            )
            return
        }
        // New stack: bottom-center of pile = tap point in world space.
        let endAnchor = world
        let stampingWithOverlay = !stampUndoIds.isEmpty,
            baseAnch = baseCarry.anchor

        if stampingWithOverlay {
            carryAnchorFollowsCursor = true
            stampPlacementOverlay = placementCarry
            if var o = stampPlacementOverlay {
                o.anchor = baseAnch
                stampPlacementOverlay = o
            }
            withAnimation(.easeOut(duration: 0.2)) {
                if var g = self.stampPlacementOverlay {
                    g.anchor = endAnchor
                    self.stampPlacementOverlay = g
                }
            }
        } else {
            carryAnchorFollowsCursor = false
            withAnimation(.easeOut(duration: 0.2)) {
                if var g = carriedGroup {
                    g.anchor = endAnchor
                    carriedGroup = g
                }
            }
        }

        let carryIDs = placementCarry.noteIDs
        let carryAtStart = placementCarry
        let stampIds = stampUndoIds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: carryPickPlaceAnimationNs)
            if stampingWithOverlay {
                guard self.stampPlacementOverlay?.noteIDs == carryIDs else { return }
                let snap = self.stampPlacementOverlay ?? carryAtStart
                let newBoard = GroupLogic.placeCarried(
                    snap,
                    placeBottomCenterWorld: endAnchor,
                    onto: nil,
                    in: self.boardNoteGroups()
                )
                self.persistence?.replaceBoardGroups(newBoard)
                self.stampPlacementOverlay = nil
                self.carryAnchorFollowsCursor = true
            } else {
                guard self.carriedGroup?.noteIDs == carryIDs else { return }
                let snap = self.carriedGroup ?? carryAtStart
                let newBoard = GroupLogic.placeCarried(
                    snap,
                    placeBottomCenterWorld: endAnchor,
                    onto: nil,
                    in: self.boardNoteGroups()
                )
                self.persistence?.replaceBoardGroups(newBoard)
                self.carriedGroup = nil
                self.carryAnchorFollowsCursor = true
            }
            self.registerPlaceUndo(undoBefore, stampIds: stampIds, actionName: "Place Notes")
            self.appendActionLog("place new stack at world (\(Int(endAnchor.x)),\(Int(endAnchor.y)))")
        }
    }

    private func placeCarriedOntoBoardGroupAnimated(
        targetID: UUID,
        modifiers: InputModifiers,
        undoBefore: UndoSnapshot,
        placementCarry: NoteGroup,
        stampUndoIds: Set<UUID>
    ) {
        guard let carriedBase = carriedGroup,
              let targetRender = activeGroups.first(where: { $0.id == targetID }) else { return }

        cancelFirstPickupLerp()

        if modifiers.shift, placementCarry.noteIDs.count > 1, !modifiers.command {
            let mergedPreview = NoteGroup(
                id: targetRender.id,
                anchor: targetRender.anchor,
                zOrder: targetRender.zOrder,
                noteIDs: targetRender.noteIDs + [placementCarry.noteIDs.last!]
            )
            let placePoint = BoardLayout.noteCenterWorld(
                group: mergedPreview,
                noteIndex: mergedPreview.noteIDs.count - 1
            )
            if let res = GroupLogic.placeCarriedTopOnly(
                placementCarry,
                placeBottomCenterWorld: placePoint,
                onto: targetID,
                in: boardNoteGroups()
            ) {
                persistence?.replaceBoardGroups(res.board)
                if stampUndoIds.isEmpty {
                    carriedGroup = res.remainingCarry
                    carryAnchorFollowsCursor = true
                    if var g = carriedGroup {
                        g.anchor = rootToWorld(bottomCenterFollowRoot())
                        carriedGroup = g
                    }
                } else if let rest = res.remainingCarry {
                    deleteNotes(Set(rest.noteIDs))
                }
                registerPlaceUndo(undoBefore, stampIds: stampUndoIds, actionName: "Place Notes")
                appendActionLog("shift place top (merge tap)")
                return
            }
        }

        let mergedPreview = NoteGroup(
            id: targetRender.id,
            anchor: targetRender.anchor,
            zOrder: targetRender.zOrder,
            noteIDs: targetRender.noteIDs + placementCarry.noteIDs
        )
        let mergedIndexOfCarryBottom = targetRender.noteIDs.count
        let endAnchor = BoardLayout.noteCenterWorld(group: mergedPreview, noteIndex: mergedIndexOfCarryBottom)

        let stampingWithOverlay = !stampUndoIds.isEmpty,
            baseAnch = carriedBase.anchor

        if stampingWithOverlay {
            carryAnchorFollowsCursor = true
            stampPlacementOverlay = placementCarry
            if var o = stampPlacementOverlay {
                o.anchor = baseAnch
                stampPlacementOverlay = o
            }
            withAnimation(.easeOut(duration: 0.2)) {
                if var g = self.stampPlacementOverlay {
                    g.anchor = endAnchor
                    self.stampPlacementOverlay = g
                }
            }
        } else {
            carryAnchorFollowsCursor = false
            withAnimation(.easeOut(duration: 0.2)) {
                if var g = carriedGroup {
                    g.anchor = endAnchor
                    carriedGroup = g
                }
            }
        }

        let carryIDs = placementCarry.noteIDs
        let carryAtStart = placementCarry
        let stampIds = stampUndoIds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: carryPickPlaceAnimationNs)
            if stampingWithOverlay {
                guard self.stampPlacementOverlay?.noteIDs == carryIDs else { return }
                let snap = self.stampPlacementOverlay ?? carryAtStart
                let newBoard = GroupLogic.placeCarried(
                    snap,
                    placeBottomCenterWorld: endAnchor,
                    onto: targetID,
                    in: self.boardNoteGroups()
                )
                self.persistence?.replaceBoardGroups(newBoard)
                self.stampPlacementOverlay = nil
                self.carryAnchorFollowsCursor = true
            } else {
                guard self.carriedGroup?.noteIDs == carryIDs else { return }
                let snap = self.carriedGroup ?? carryAtStart
                let newBoard = GroupLogic.placeCarried(
                    snap,
                    placeBottomCenterWorld: endAnchor,
                    onto: targetID,
                    in: self.boardNoteGroups()
                )
                self.persistence?.replaceBoardGroups(newBoard)
                self.carriedGroup = nil
                self.carryAnchorFollowsCursor = true
            }
            self.registerPlaceUndo(undoBefore, stampIds: stampIds, actionName: "Place Notes")
            self.appendActionLog("merge carry onto group \(targetID.uuidString.prefix(8))…")
        }
    }

    private func cycleBoardGroup(id: UUID, forward: Bool) {
        var groups = boardNoteGroups()
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        if forward {
            groups[idx] = GroupLogic.cycleTopToBottom(groups[idx])
        } else {
            groups[idx] = GroupLogic.cycleBottomToTop(groups[idx])
        }
        persistence?.replaceBoardGroups(groups)
        appendActionLog("cycle group \(id.uuidString.prefix(8))… \(forward ? "fwd" : "back")")
    }

    private func createNoteAndEdit(centeredAt worldCenter: CGPoint) {
        if let noteID = persistence?.createNote(atWorldCenter: worldCenter, colour: noteColourPicked) {
            editingNoteID = noteID
            appendActionLog("create note \(noteID.uuidString.prefix(8))…")
            finishOneShotTool()
        }
    }

    // MARK: - Strings Geometry Helpers

    /// Groups not on the board right now: carried in hand, or mid stamp-placement.
    private func inHandGroups() -> [NoteGroup] {
        var groups: [NoteGroup] = []
        if let c = carriedGroup { groups.append(c) }
        if let s = stampPlacementOverlay { groups.append(s) }
        return groups
    }

    func anchorPoint(for node: NodeID) -> CGPoint? {
        switch node {
        case .note(let nid):
            if let render = activeGroups.first(where: { $0.noteIDs.contains(nid) }),
               let idx = render.noteIDs.firstIndex(of: nid) {
                let group = NoteGroup(id: render.id, anchor: render.anchor, zOrder: render.zOrder, noteIDs: render.noteIDs)
                return BoardLayout.noteCenterWorld(group: group, noteIndex: idx)
            }
            for group in inHandGroups() {
                if let idx = group.noteIDs.firstIndex(of: nid) {
                    return BoardLayout.noteCenterWorld(group: group, noteIndex: idx)
                }
            }
            return nil
        case .stack(let gid):
            if let render = activeGroups.first(where: { $0.id == gid }) { return render.anchor }
            return inHandGroups().first(where: { $0.id == gid })?.anchor
        case .pin(let pid):
            // Pins are normalised to their image, so this follows the image
            // through any move, resize or resample with no extra bookkeeping.
            guard let pin = pins[pid], let asset = image(withID: pin.imageID) else { return nil }
            return asset.worldPoint(of: pin)
        }
    }

    func elasticControlPoint(a: CGPoint, b: CGPoint, isDraft: Bool = false) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dist = max(1, hypot(dx, dy))
        let nx = -dy / dist
        let ny = dx / dist
        let k: CGFloat = isDraft ? 0.12 : 0.08
        let mag = min(max(dist * k, 12), 48)
        return CGPoint(x: mid.x + nx * mag, y: mid.y + ny * mag)
    }

    /// Signed position of a link within the set sharing its endpoint pair, centred on zero.
    private func spreadIndex(for link: Link) -> CGFloat {
        let key = link.pairKey
        let siblings = links.values
            .filter { $0.pairKey == key }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }
        guard siblings.count > 1, let idx = siblings.firstIndex(where: { $0.id == link.id }) else { return 0 }
        return CGFloat(idx) - CGFloat(siblings.count - 1) / 2
    }

    /// Curve control point, fanned perpendicular to the chord so parallel links stay distinguishable.
    func controlPoint(for link: Link, a: CGPoint, b: CGPoint) -> CGPoint {
        let base = elasticControlPoint(a: a, b: b)
        let spread = spreadIndex(for: link)
        guard spread != 0 else { return base }
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dist = max(1, hypot(dx, dy))
        let nx = -dy / dist
        let ny = dx / dist
        let spacing: CGFloat = 28
        return CGPoint(x: base.x + nx * spread * spacing, y: base.y + ny * spread * spacing)
    }

    /// The three control values of a link's quad curve, in world space.
    func curveGeometry(for link: Link) -> LinkCurveGeometry? {
        guard let a = anchorPoint(for: link.from), let b = anchorPoint(for: link.to) else { return nil }
        return LinkCurveGeometry(a: a, control: controlPoint(for: link, a: a, b: b), b: b)
    }

    func path(for link: Link) -> Path? {
        guard let geo = curveGeometry(for: link) else { return nil }
        var p = Path()
        p.move(to: geo.a)
        p.addQuadCurve(to: geo.b, control: geo.control)
        return p
    }

    /// Point on the curve at t = 0.5, where the hover affordance sits.
    func midpoint(for link: Link) -> CGPoint? {
        guard let geo = curveGeometry(for: link) else { return nil }
        return CGPoint(
            x: 0.25 * geo.a.x + 0.5 * geo.control.x + 0.25 * geo.b.x,
            y: 0.25 * geo.a.y + 0.5 * geo.control.y + 0.25 * geo.b.y
        )
    }

    func draftPath() -> Path? {
        guard let src = linkDraftSource, let a = anchorPoint(for: src), let bRoot = linkDraftCursor else { return nil }
        let b = rootToWorld(bRoot)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: elasticControlPoint(a: a, b: b, isDraft: true))
        return p
    }
}
