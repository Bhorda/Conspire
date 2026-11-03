//
//  WhiteboardStore+Fields.swift
//  Conspire
//

import CoreGraphics
import Foundation
import SwiftData
import SwiftUI

/// What a note shows for one field it sits inside. Deliberately light: holding
/// the whole `Field` here would drag its ring into every note's view body.
struct FieldChip: Identifiable, Equatable {
    let id: UUID
    let label: String
    let colourIndex: Int
}

/// Outline arc under the cursor, so a hover shows what a drag would move.
struct FieldEdgeHover: Equatable {
    var fieldID: UUID
    /// Ring points inside the falloff, in walk order. Empty in handle mode.
    var points: FieldRing
}

/// An in-flight reshape or move of one field.
struct FieldGesture {
    enum Kind {
        /// Push/pull with an arc-length falloff.
        case clay(weights: [CGFloat])
        /// Drag one control handle; influence tapers to its neighbours.
        case handle(index: Int, stride: Int)
        /// Translate the whole field, optionally carrying its notes.
        case move(groupIDs: Set<UUID>)
    }

    var kind: Kind
    var fieldID: UUID
    var startWorld: CGPoint
    var baseRing: FieldRing
    var didChange: Bool = false
}

@MainActor
extension WhiteboardStore {

    // MARK: - Lookup

    func field(withID id: UUID?) -> Field? {
        guard let id else { return nil }
        return fields.first { $0.id == id }
    }

    /// Topmost field whose outline encloses `point`.
    func field(atWorld point: CGPoint) -> Field? {
        fields.last { FieldGeometry.contains($0.ring, point) }
    }

    /// World-space centre of a group's footprint — what decides field membership.
    func groupCentreWorld(_ render: NoteGroupRender) -> CGPoint {
        let group = NoteGroup(
            id: render.id, anchor: render.anchor, zOrder: render.zOrder, noteIDs: render.noteIDs
        )
        let rect = BoardLayout.groupUnionWorldRect(group)
        guard !rect.isNull else { return render.anchor }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Whole stacks move together, so membership for a ⌘-drag is decided per group.
    func memberGroupIDs(of field: Field) -> Set<UUID> {
        var ids = Set<UUID>()
        for group in activeGroups where FieldGeometry.contains(field.ring, groupCentreWorld(group)) {
            ids.insert(group.id)
        }
        return ids
    }

    /// Notes inside the field — what the label counts, matching the chips on the cards.
    func memberNoteCount(of field: Field) -> Int {
        fieldNoteCounts[field.id] ?? 0
    }

    /// Fields enclosing a point — a note can sit in several overlapping fields at once.
    func fields(containingWorldPoint point: CGPoint) -> [Field] {
        fields.filter { FieldGeometry.contains($0.ring, point) }
    }

    /// Recomputes which notes sit in which fields.
    ///
    /// Call this when the fields or the notes move — never from a view body. A
    /// bounding-box reject keeps it cheap: the point-in-polygon walk only runs
    /// for notes actually over a field.
    func rebuildFieldMembership() {
        guard !fields.isEmpty, !activeGroups.isEmpty else {
            if !noteFieldChips.isEmpty { noteFieldChips = [:] }
            if !fieldNoteCounts.isEmpty { fieldNoteCounts = [:] }
            return
        }

        let boxes = fields.map { FieldGeometry.bounds($0.ring) }
        var chips: [UUID: [FieldChip]] = [:]
        var counts: [UUID: Int] = [:]

        for render in activeGroups {
            let group = NoteGroup(
                id: render.id, anchor: render.anchor, zOrder: render.zOrder, noteIDs: render.noteIDs
            )
            let carry = fieldMoveGroupIDs.contains(render.id) ? fieldMoveOffset : .zero
            for index in render.noteIDs.indices {
                var centre = BoardLayout.noteCenterWorld(group: group, noteIndex: index)
                centre.x += carry.width
                centre.y += carry.height

                var hits: [FieldChip] = []
                for (i, field) in fields.enumerated() {
                    guard boxes[i].contains(centre) else { continue }
                    guard FieldGeometry.contains(field.ring, centre) else { continue }
                    hits.append(
                        FieldChip(id: field.id, label: field.label, colourIndex: field.colourIndex)
                    )
                    counts[field.id, default: 0] += 1
                }
                if !hits.isEmpty { chips[render.noteIDs[index]] = hits }
            }
        }

        if chips != noteFieldChips { noteFieldChips = chips }
        if counts != fieldNoteCounts { fieldNoteCounts = counts }
    }

    // MARK: - Hover

    func updateFieldHover(atWorld point: CGPoint) {
        guard placementMode != .field, fieldGesture == nil, !fields.isEmpty else {
            if fieldHoverEdge != nil { fieldHoverEdge = nil }
            return
        }
        let grab = FieldGeometry.edgeGrab / max(canvasScale, 0.01)
        var found: FieldEdgeHover?
        for field in fields.reversed() {
            // Reject on the bounding box first: this runs on every mouse move.
            guard FieldGeometry.bounds(field.ring).insetBy(dx: -grab, dy: -grab).contains(point)
            else { continue }
            guard let near = FieldGeometry.nearest(on: field.ring, to: point), near.distance <= grab
            else { continue }
            switch fieldReshapeMode {
            case .clay:
                let influence = FieldGeometry.arcInfluence(
                    ring: field.ring, near: near, radius: fieldBrushRadius
                )
                found = FieldEdgeHover(
                    fieldID: field.id,
                    points: influence.indices.map { field.ring[$0] }
                )
            case .handles:
                found = FieldEdgeHover(fieldID: field.id, points: [])
            }
            break
        }
        if found != fieldHoverEdge { fieldHoverEdge = found }
    }

    // MARK: - Drawing (pencil)

    func updateFieldStroke(startRoot: CGPoint, currentRoot: CGPoint) {
        let carve = InputModifiers.current().option

        if fieldDraftStroke.isEmpty {
            let start = rootToWorld(startRoot)
            fieldDraftStroke = [start]
            fieldDraftIsCarve = carve
            fieldDraftHostID = carve ? nil : field(atWorld: start)?.id
        } else if carve != fieldDraftIsCarve {
            fieldDraftIsCarve = carve
            fieldDraftHostID = carve ? nil : field(atWorld: fieldDraftStroke[0])?.id
        }

        let point = rootToWorld(currentRoot)
        let minStep = 2 / max(canvasScale, 0.01)
        if let last = fieldDraftStroke.last, FieldGeometry.distance(last, point) > minStep {
            fieldDraftStroke.append(point)
        }
    }

    /// Lands the drawn stroke. Every path that actually changes the board hands
    /// the pencil back; a stroke too small to mean anything leaves it in place,
    /// so a slip does not cost you the tool.
    func endFieldStroke() {
        let raw = fieldDraftStroke
        let carve = fieldDraftIsCarve
        let hostID = fieldDraftHostID
        fieldDraftStroke = []
        fieldDraftHostID = nil
        fieldDraftIsCarve = false

        guard raw.count >= 4, abs(FieldGeometry.area(raw)) >= FieldGeometry.minArea else { return }
        let stroke = FieldGeometry.normalize(raw, passes: fieldTidyPasses)
        guard stroke.count >= 6 else { return }

        let before = fields

        if carve {
            carveFields(with: stroke)
            rebuildFieldMembership()
            registerFieldUndo(before, actionName: "Carve Field")
            finishOneShotTool()
            return
        }

        // A stroke that began inside a field extends that field.
        if let hostID, let index = fields.firstIndex(where: { $0.id == hostID }) {
            guard let merged = FieldGeometry.combine(
                fields[index].ring, stroke, mode: .union, soft: fieldJoinSoftness
            ) else { return }
            fields[index].ring = merged
            fields[index].updatedAt = Date()
            persistField(fields[index])
            selectedFieldID = hostID
            rebuildFieldMembership()
            registerFieldUndo(before, actionName: "Extend Field")
            appendActionLog("field extended")
            finishOneShotTool()
            return
        }

        let field = Field(
            ring: FieldGeometry.repairIfNeeded(stroke),
            colourIndex: fieldColourPicked,
            label: nextFieldLabel()
        )
        fields.append(field)
        persistField(field)
        selectedFieldID = field.id
        rebuildFieldMembership()
        registerFieldUndo(before, actionName: "Draw Field")
        appendActionLog("field created")
        finishOneShotTool()
    }

    /// Subtract the stroke from every field it touches, dropping any erased entirely.
    private func carveFields(with stroke: FieldRing) {
        var survivors: [Field] = []
        var removed: [UUID] = []

        for var field in fields {
            let touches = stroke.contains { FieldGeometry.contains(field.ring, $0) }
                || field.ring.contains { FieldGeometry.contains(stroke, $0) }
            guard touches else {
                survivors.append(field)
                continue
            }
            if let carved = FieldGeometry.combine(
                field.ring, stroke, mode: .subtract, soft: fieldJoinSoftness
            ) {
                field.ring = carved
                field.updatedAt = Date()
                persistField(field)
                survivors.append(field)
            } else {
                removed.append(field.id)
            }
        }

        fields = survivors
        for id in removed { deleteFieldEntity(id: id) }
        if let selected = selectedFieldID, !fields.contains(where: { $0.id == selected }) {
            selectedFieldID = nil
        }
        appendActionLog("field carved")
    }

    private func nextFieldLabel() -> String {
        "Field \(fields.count + 1)"
    }

    // MARK: - Reshape / move (hand)

    func beginFieldGesture(atRoot rootPoint: CGPoint) {
        guard placementMode != .field, editingNoteID == nil, carriedGroup == nil else { return }
        cancelFieldGesture()

        let world = rootToWorld(rootPoint)
        let grab = FieldGeometry.edgeGrab / max(canvasScale, 0.01)

        // Outline first: an edge grab wins over the interior underneath it.
        for field in fields.reversed() {
            guard let near = FieldGeometry.nearest(on: field.ring, to: world), near.distance <= grab
            else { continue }
            selectedFieldID = field.id
            switch fieldReshapeMode {
            case .clay:
                let influence = FieldGeometry.arcInfluence(
                    ring: field.ring, near: near, radius: fieldBrushRadius
                )
                fieldGesture = FieldGesture(
                    kind: .clay(weights: influence.weights),
                    fieldID: field.id,
                    startWorld: world,
                    baseRing: field.ring
                )
            case .handles:
                let handles = FieldGeometry.handleIndices(field.ring)
                guard let closest = handles.min(by: {
                    FieldGeometry.distance(field.ring[$0], world)
                        < FieldGeometry.distance(field.ring[$1], world)
                }) else { return }
                fieldGesture = FieldGesture(
                    kind: .handle(index: closest, stride: FieldGeometry.handleStride(field.ring)),
                    fieldID: field.id,
                    startWorld: world,
                    baseRing: field.ring
                )
            }
            return
        }

        // Interior: select, and drag to move. ⌘ brings the notes inside along.
        guard let field = field(atWorld: world) else { return }
        selectedFieldID = field.id
        let carryNotes = InputModifiers.current().command
        let groupIDs = carryNotes ? memberGroupIDs(of: field) : []
        fieldMoveGroupIDs = groupIDs
        fieldMoveOffset = .zero
        fieldGesture = FieldGesture(
            kind: .move(groupIDs: groupIDs),
            fieldID: field.id,
            startWorld: world,
            baseRing: field.ring
        )
    }

    func updateFieldGesture(atRoot rootPoint: CGPoint) {
        guard var gesture = fieldGesture,
              let index = fields.firstIndex(where: { $0.id == gesture.fieldID })
        else { return }

        let world = rootToWorld(rootPoint)
        let dx = world.x - gesture.startWorld.x
        let dy = world.y - gesture.startWorld.y
        if dx != 0 || dy != 0 { gesture.didChange = true }

        switch gesture.kind {
        case .clay(let weights):
            fields[index].ring = gesture.baseRing.enumerated().map { i, p in
                let w = i < weights.count ? weights[i] : 0
                return CGPoint(x: p.x + dx * w, y: p.y + dy * w)
            }

        case .handle(let handleIndex, let stride):
            let n = gesture.baseRing.count
            fields[index].ring = gesture.baseRing.enumerated().map { i, p in
                var d = abs(i - handleIndex)
                d = min(d, n - d)
                guard d < stride else { return p }
                let w = 0.5 * (1 + cos(.pi * Double(d) / Double(stride)))
                return CGPoint(x: p.x + dx * CGFloat(w), y: p.y + dy * CGFloat(w))
            }

        case .move:
            fields[index].ring = gesture.baseRing.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            fieldMoveOffset = CGSize(width: dx, height: dy)
        }

        fieldGesture = gesture
        fieldHoverEdge = nil
        rebuildFieldMembership()
    }

    func endFieldGesture() {
        guard let gesture = fieldGesture else { return }
        fieldGesture = nil

        guard let index = fields.firstIndex(where: { $0.id == gesture.fieldID }) else {
            fieldMoveGroupIDs = []
            fieldMoveOffset = .zero
            return
        }

        // A press with no movement is just a selection — leave the ring and undo alone.
        guard gesture.didChange else {
            fieldMoveGroupIDs = []
            fieldMoveOffset = .zero
            return
        }

        let before = fields.enumerated().map { i, f -> Field in
            var copy = f
            if i == index { copy.ring = gesture.baseRing }
            return copy
        }

        switch gesture.kind {
        case .clay:
            // Re-space after a drag stretched the gaps, then fix any crossing.
            let resampled = FieldGeometry.resampleClosed(
                fields[index].ring, spacing: FieldGeometry.ringSpacing
            )
            fields[index].ring = FieldGeometry.repairIfNeeded(resampled)
        case .handle:
            fields[index].ring = FieldGeometry.repairIfNeeded(fields[index].ring)
        case .move(let groupIDs):
            commitFieldMove(groupIDs: groupIDs, offset: fieldMoveOffset)
        }

        fieldMoveGroupIDs = []
        fieldMoveOffset = .zero
        fields[index].updatedAt = Date()
        persistField(fields[index])
        rebuildFieldMembership()
        registerFieldUndo(before, actionName: "Reshape Field")
    }

    func cancelFieldGesture() {
        if let gesture = fieldGesture,
           let index = fields.firstIndex(where: { $0.id == gesture.fieldID }) {
            fields[index].ring = gesture.baseRing
        }
        fieldGesture = nil
        fieldMoveGroupIDs = []
        fieldMoveOffset = .zero
        fieldDraftStroke = []
        fieldDraftHostID = nil
        fieldDraftIsCarve = false
    }

    /// Writes the previewed offset into the carried groups' anchors.
    private func commitFieldMove(groupIDs: Set<UUID>, offset: CGSize) {
        guard !groupIDs.isEmpty, offset != .zero else { return }
        let updated = activeGroups.map { render -> NoteGroup in
            var anchor = render.anchor
            if groupIDs.contains(render.id) {
                anchor.x += offset.width
                anchor.y += offset.height
            }
            return NoteGroup(
                id: render.id, anchor: anchor, zOrder: render.zOrder, noteIDs: render.noteIDs
            )
        }
        persistence?.replaceBoardGroups(updated)
    }

    // MARK: - Selection

    func selectField(_ id: UUID?) {
        selectedFieldID = id
        // One selection at a time, so Delete and Escape always have an
        // unambiguous target.
        if id != nil {
            selectedImageID = nil
            selectedNoteID = nil
        }
    }

    func setSelectedFieldLabel(_ label: String) {
        guard let id = selectedFieldID, let index = fields.firstIndex(where: { $0.id == id })
        else { return }
        fields[index].label = label.isEmpty ? "Field" : label
        fields[index].updatedAt = Date()
        persistField(fields[index])
        rebuildFieldMembership()
    }

    func deleteSelectedField() {
        guard let id = selectedFieldID else { return }
        let before = fields
        fields.removeAll { $0.id == id }
        deleteFieldEntity(id: id)
        selectedFieldID = nil
        fieldHoverEdge = nil
        rebuildFieldMembership()
        registerFieldUndo(before, actionName: "Delete Field")
        appendActionLog("field deleted")
    }

    // MARK: - Undo

    func registerFieldUndo(_ stateToRestore: [Field], actionName: String) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            let beforeThisUndo = target.fields
            target.fields = stateToRestore
            target.persistAllFields()
            target.rebuildFieldMembership()
            if let selected = target.selectedFieldID,
               !stateToRestore.contains(where: { $0.id == selected }) {
                target.selectedFieldID = nil
            }
            target.registerFieldUndo(beforeThisUndo, actionName: actionName)
        }
        manager.setActionName(actionName)
    }

    // MARK: - Persistence

    func loadFieldsForActiveBoard() {
        guard let context = persistence?.context, let boardID = activeBoardID else {
            fields = []
            rebuildFieldMembership()
            return
        }
        let predicate = #Predicate<FieldEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<FieldEntity>(predicate: predicate))) ?? []
        fields = entities
            .map { $0.toField() }
            .filter { $0.ring.count > 2 }
            .sorted { $0.createdAt < $1.createdAt }
        rebuildFieldMembership()
    }

    func persistField(_ field: Field) {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        let targetID = field.id
        let predicate = #Predicate<FieldEntity> { $0.id == targetID }
        if let entity = try? context.fetch(FetchDescriptor<FieldEntity>(predicate: predicate)).first {
            entity.ringBlob = FieldEntity.encodeRing(field.ring)
            entity.colorIndex = field.colourIndex
            entity.label = field.label
            entity.updatedAt = field.updatedAt
        } else {
            context.insert(FieldEntity(boardID: boardID, field: field))
        }
        try? context.save()
    }

    /// Reconciles the whole set — used after an undo replaces `fields` wholesale.
    func persistAllFields() {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        let predicate = #Predicate<FieldEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<FieldEntity>(predicate: predicate))) ?? []
        let live = Set(fields.map(\.id))
        for entity in entities where !live.contains(entity.id) {
            context.delete(entity)
        }
        try? context.save()
        for field in fields { persistField(field) }
    }

    func deleteFieldEntity(id: UUID) {
        guard let context = persistence?.context else { return }
        let targetID = id
        let predicate = #Predicate<FieldEntity> { $0.id == targetID }
        if let entity = try? context.fetch(FetchDescriptor<FieldEntity>(predicate: predicate)).first {
            context.delete(entity)
            try? context.save()
        }
    }
}
