//
//  GroupLogic.swift
//  Conspire
//

import CoreGraphics
import Foundation

/// A pile on the board or in-hand: anchor = world-space center of the bottom (index 0) note; `noteIDs` bottom → top.
struct NoteGroup: Equatable, Identifiable, Sendable {
    var id: UUID
    var anchor: CGPoint
    var zOrder: Int
    var noteIDs: [UUID]
}

enum GroupLogic {
    /// Remove `pickedGroupID` from `groups` and merge into `carry` (append picked on top) or become new carry.
    static func pickUp(
        pickedGroupID: UUID,
        from groups: [NoteGroup],
        into carry: NoteGroup?
    ) -> (remaining: [NoteGroup], carried: NoteGroup)? {
        guard let idx = groups.firstIndex(where: { $0.id == pickedGroupID }) else { return nil }
        var remaining = groups
        let picked = remaining.remove(at: idx)
        if var existing = carry {
            existing.noteIDs = existing.noteIDs + picked.noteIDs
            return (remaining, existing)
        }
        return (remaining, picked)
    }

    /// Peel only the top note from a board stack into the hand. Returns `nil` if the stack has a single note (caller should use full `pickUp`).
    static func pickUpTopNote(
        pickedGroupID: UUID,
        from groups: [NoteGroup],
        into carry: NoteGroup?
    ) -> (remaining: [NoteGroup], carried: NoteGroup)? {
        guard let idx = groups.firstIndex(where: { $0.id == pickedGroupID }) else { return nil }
        var picked = groups[idx]
        guard picked.noteIDs.count > 1 else { return nil }
        let topId = picked.noteIDs.removeLast()
        var remaining = groups
        remaining[idx] = picked

        if var existing = carry {
            existing.noteIDs = existing.noteIDs + [topId]
            return (remaining, existing)
        }
        let newCarry = NoteGroup(
            id: UUID(),
            anchor: picked.anchor,
            zOrder: picked.zOrder,
            noteIDs: [topId]
        )
        return (remaining, newCarry)
    }

    /// Commit only the top carried note; returns `nil` if carry has a single note (use full `placeCarried`).
    static func placeCarriedTopOnly(
        _ carry: NoteGroup,
        placeBottomCenterWorld: CGPoint,
        onto targetID: UUID?,
        in groups: [NoteGroup]
    ) -> (board: [NoteGroup], remainingCarry: NoteGroup?)? {
        guard carry.noteIDs.count > 1 else { return nil }
        var ids = carry.noteIDs
        let topId = ids.removeLast()
        let topOnly = NoteGroup(id: carry.id, anchor: carry.anchor, zOrder: carry.zOrder, noteIDs: [topId])
        let board = placeCarried(topOnly, placeBottomCenterWorld: placeBottomCenterWorld, onto: targetID, in: groups)
        if ids.isEmpty {
            return (board, nil)
        }
        let rest = NoteGroup(id: carry.id, anchor: carry.anchor, zOrder: carry.zOrder, noteIDs: ids)
        return (board, rest)
    }

    /// Drop carried notes onto an optional target group (merge on top) or create a new group at `placeBottomCenterWorld`.
    static func placeCarried(
        _ carry: NoteGroup,
        placeBottomCenterWorld: CGPoint,
        onto targetID: UUID?,
        in groups: [NoteGroup]
    ) -> [NoteGroup] {
        if let tid = targetID, let tIdx = groups.firstIndex(where: { $0.id == tid }) {
            var out = groups
            var target = out[tIdx]
            target.noteIDs = target.noteIDs + carry.noteIDs
            out[tIdx] = target
            return bringToFront(groupID: target.id, in: out)
        }
        let maxZ = groups.map(\.zOrder).max() ?? -1
        let newGroup = NoteGroup(
            id: UUID(),
            anchor: placeBottomCenterWorld,
            zOrder: maxZ + 1,
            noteIDs: carry.noteIDs
        )
        return bringToFront(groupID: newGroup.id, in: groups + [newGroup])
    }

    static func cycleTopToBottom(_ g: NoteGroup) -> NoteGroup {
        var x = g
        guard x.noteIDs.count > 1 else { return x }
        var ids = x.noteIDs
        let top = ids.removeLast()
        ids.insert(top, at: 0)
        x.noteIDs = ids
        return x
    }

    static func cycleBottomToTop(_ g: NoteGroup) -> NoteGroup {
        var x = g
        guard x.noteIDs.count > 1 else { return x }
        var ids = x.noteIDs
        let bottom = ids.removeFirst()
        ids.append(bottom)
        x.noteIDs = ids
        return x
    }

    /// Higher `zOrder` draws on top; renumbers to 0...(n-1) sorted by z then stable id.
    static func bringToFront(groupID: UUID, in groups: [NoteGroup]) -> [NoteGroup] {
        let maxZ = groups.map(\.zOrder).max() ?? -1
        var out = groups
        guard let i = out.firstIndex(where: { $0.id == groupID }) else { return groups }
        out[i].zOrder = maxZ + 1
        let sorted = out.sorted {
            if $0.zOrder != $1.zOrder { return $0.zOrder < $1.zOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        return sorted.enumerated().map { j, g in
            var gg = g
            gg.zOrder = j
            return gg
        }
    }
}
