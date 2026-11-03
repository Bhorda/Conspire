//
//  ConspireTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Conspire

struct GroupLogicTests {
    @Test func pickUp_intoEmptyCarry_removesFromBoard() {
        let a = UUID(), b = UUID()
        let g = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [a, b])
        let result = GroupLogic.pickUp(pickedGroupID: g.id, from: [g], into: nil)
        #expect(result?.remaining == [])
        #expect(result?.carried.noteIDs == [a, b])
    }

    @Test func pickUp_appendsOntoCarry() {
        let h1 = UUID(), p1 = UUID(), p2 = UUID()
        let carry = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [h1])
        let picked = NoteGroup(id: UUID(), anchor: CGPoint(x: 10, y: 10), zOrder: 1, noteIDs: [p1, p2])
        let result = GroupLogic.pickUp(pickedGroupID: picked.id, from: [carry, picked], into: carry)
        #expect(result?.remaining.map(\.id) == [carry.id])
        #expect(result?.carried.noteIDs == [h1, p1, p2])
    }

    @Test func placeCarried_mergeOrder() {
        let t1 = UUID(), t2 = UUID()
        let c1 = UUID(), c2 = UUID()
        let target = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [t1, t2])
        let carry = NoteGroup(id: UUID(), anchor: CGPoint(x: 5, y: 5), zOrder: 1, noteIDs: [c1, c2])
        let out = GroupLogic.placeCarried(carry, placeBottomCenterWorld: .zero, onto: target.id, in: [target])
        #expect(out.count == 1)
        #expect(out[0].noteIDs == [t1, t2, c1, c2])
    }

    @Test func cycleTopToBottom() {
        let ids = [UUID(), UUID(), UUID()]
        var g = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: ids)
        g = GroupLogic.cycleTopToBottom(g)
        #expect(g.noteIDs == [ids[2], ids[0], ids[1]])
    }

    @Test func pickUpTopNote_twoNotes_peelsTop() {
        let bottom = UUID(), top = UUID()
        let g = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [bottom, top])
        let r = GroupLogic.pickUpTopNote(pickedGroupID: g.id, from: [g], into: nil)
        #expect(r?.remaining.count == 1)
        #expect(r?.remaining[0].noteIDs == [bottom])
        #expect(r?.remaining[0].id == g.id)
        #expect(r?.carried.noteIDs == [top])
    }

    @Test func pickUpTopNote_singleNote_returnsNil() {
        let a = UUID()
        let g = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [a])
        let r = GroupLogic.pickUpTopNote(pickedGroupID: g.id, from: [g], into: nil)
        #expect(r == nil)
    }

    @Test func pickUpTopNote_appendsTopOntoCarry() {
        let h = UUID()
        let b = UUID(), t = UUID()
        let carry = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [h])
        let board = NoteGroup(id: UUID(), anchor: CGPoint(x: 1, y: 1), zOrder: 1, noteIDs: [b, t])
        let r = GroupLogic.pickUpTopNote(pickedGroupID: board.id, from: [carry, board], into: carry)
        #expect(r?.remaining.count == 2)
        #expect(r?.remaining.first(where: { $0.id == board.id })?.noteIDs == [b])
        #expect(r?.carried.noteIDs == [h, t])
    }

    @Test func placeCarriedTopOnly_leavesRemainderInHand() {
        let t1 = UUID(), t2 = UUID()
        let c1 = UUID(), c2 = UUID(), c3 = UUID()
        let target = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [t1, t2])
        let carry = NoteGroup(id: UUID(), anchor: CGPoint(x: 5, y: 5), zOrder: 1, noteIDs: [c1, c2, c3])
        let r = GroupLogic.placeCarriedTopOnly(carry, placeBottomCenterWorld: .zero, onto: target.id, in: [target])
        #expect(r?.board.count == 1)
        #expect(r?.board[0].noteIDs == [t1, t2, c3])
        #expect(r?.remainingCarry?.noteIDs == [c1, c2])
    }

    @Test func placeCarriedTopOnly_singleCarry_returnsNil() {
        let t = UUID()
        let c = UUID()
        let target = NoteGroup(id: UUID(), anchor: .zero, zOrder: 0, noteIDs: [t])
        let carry = NoteGroup(id: UUID(), anchor: .zero, zOrder: 1, noteIDs: [c])
        let r = GroupLogic.placeCarriedTopOnly(carry, placeBottomCenterWorld: .zero, onto: target.id, in: [target])
        #expect(r == nil)
    }
}

