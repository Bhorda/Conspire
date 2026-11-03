//
//  BoardLayout.swift
//  Conspire
//

import CoreGraphics
import Foundation

enum BoardLayout {
    private static let noteSize = WhiteboardStyle.noteSize
    private static let stackOffset = WhiteboardStyle.stackDepthOffset

    /// Top-left of note at `index` in world space (anchor = center of index-0 note).
    static func noteTopLeftWorld(group: NoteGroup, noteIndex: Int) -> CGPoint {
        let bottomTopLeft = CGPoint(
            x: group.anchor.x - noteSize.width / 2,
            y: group.anchor.y - noteSize.height / 2
        )
        return CGPoint(
            x: bottomTopLeft.x + CGFloat(noteIndex) * stackOffset.width,
            y: bottomTopLeft.y + CGFloat(noteIndex) * stackOffset.height
        )
    }

    static func noteWorldRect(group: NoteGroup, noteIndex: Int) -> CGRect {
        let o = noteTopLeftWorld(group: group, noteIndex: noteIndex)
        return CGRect(origin: o, size: noteSize)
    }

    static func noteCenterWorld(group: NoteGroup, noteIndex: Int) -> CGPoint {
        let r = noteWorldRect(group: group, noteIndex: noteIndex)
        return CGPoint(x: r.midX, y: r.midY)
    }

    static func groupUnionWorldRect(_ group: NoteGroup) -> CGRect {
        guard !group.noteIDs.isEmpty else { return .null }
        var r = noteWorldRect(group: group, noteIndex: 0)
        for i in 1..<group.noteIDs.count {
            r = r.union(noteWorldRect(group: group, noteIndex: i))
        }
        return r
    }

    /// Hit test top-to-bottom draw order: iterate groups with highest zOrder last (front).
    static func hitGroup(world: CGPoint, groups: [NoteGroup]) -> UUID? {
        let sorted = groups.sorted {
            if $0.zOrder != $1.zOrder { return $0.zOrder < $1.zOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        for group in sorted.reversed() {
            if groupUnionWorldRect(group).contains(world) { return group.id }
        }
        return nil
    }

    /// World-space union of carried group (same layout as board).
    static func carriedUnionWorldRect(_ carry: NoteGroup) -> CGRect {
        groupUnionWorldRect(carry)
    }
}
