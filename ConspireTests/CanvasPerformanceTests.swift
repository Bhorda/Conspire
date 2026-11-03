//
//  CanvasPerformanceTests.swift
//  ConspireTests
//
//  Measurements for the per-frame canvas work. These print timings rather than
//  asserting thresholds: machine-dependent numbers make brittle gates, but the
//  before/after comparison is what guides the optimisation work.
//

import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Conspire

@MainActor
private func makeBoard(notes: Int) throws -> (WhiteboardStore, WhiteboardPersistenceService) {
    let container = try ModelContainer(
        for: BoardEntity.self, NoteEntity.self, NoteGroupEntity.self,
             LinkEntity.self, FieldEntity.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let service = WhiteboardPersistenceService()
    service.configure(context: ModelContext(container))
    service.bootstrap()

    let store = WhiteboardStore()
    store.persistence = service
    store.activeBoardID = service.activeBoardID

    for i in 0..<notes {
        let col = CGFloat(i % 6) * 220 - 660
        let row = CGFloat(i / 6) * 180 - 450
        _ = service.createNote(atWorldCenter: CGPoint(x: col, y: row), colour: i % 3)
    }
    return (store, service)
}

private func blob(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> FieldRing {
    FieldGeometry.normalize((0..<70).map { i in
        let a = CGFloat(i) / 70 * .pi * 2
        let rr = r * (1 + 0.1 * sin(a * 3 + 1))
        return CGPoint(x: cx + cos(a) * rr, y: cy + sin(a) * rr * 0.8)
    }, passes: 2)
}

private let perfLogPath = "/tmp/conspire-perf.txt"

private func perfLog(_ line: String) {
    let data = (line + "\n").data(using: .utf8)!
    if let handle = FileHandle(forWritingAtPath: perfLogPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: perfLogPath))
    }
}

private func measure(_ label: String, iterations: Int, _ body: () -> Void) {
    body()
    let start = Date()
    for _ in 0..<iterations { body() }
    let total = Date().timeIntervalSince(start)
    let per = total / Double(iterations) * 1000
    perfLog(String(format: "  %-44@ %8.3f ms/op", label as NSString, per))
}

struct CanvasPerformanceTests {

    /// What one scroll-wheel tick costs today: the viewport write-through to SwiftData.
    @Test @MainActor func costOfPersistingPanPerScrollEvent() throws {
        let (_, service) = try makeBoard(notes: 30)
        perfLog("[perf] viewport persistence")
        var i = 0.0
        measure("setCanvasPan (one scroll event)", iterations: 200) {
            i += 1
            service.setCanvasPan(CGSize(width: i, height: i))
        }
    }

    /// Field membership, recomputed inside view bodies on every render.
    @Test @MainActor func costOfFieldMembershipPerFrame() throws {
        let (store, _) = try makeBoard(notes: 30)
        store.fields = [
            Field(ring: blob(-200, -150, 320), colourIndex: 0, label: "Expensive"),
            Field(ring: blob(250, 100, 300), colourIndex: 1, label: "High impact"),
            Field(ring: blob(0, 320, 280), colourIndex: 2, label: "Later"),
        ]
        let entries = store.noteDrawEntries
        perfLog("[perf] field membership (3 fields, \(entries.count) notes)")

        store.rebuildFieldMembership()
        measure("chips: cache read x notes", iterations: 50) {
            for entry in entries { _ = store.noteFieldChips[entry.noteID] ?? [] }
        }
        measure("labels: memberNoteCount x fields", iterations: 50) {
            for field in store.fields { _ = store.memberNoteCount(of: field) }
        }
        measure("rebuildFieldMembership (on change only)", iterations: 50) {
            store.rebuildFieldMembership()
        }
        measure("noteDrawEntries rebuild", iterations: 50) {
            _ = store.noteDrawEntries
        }
    }

    /// Outline paths, rebuilt from the ring on every render.
    @Test @MainActor func costOfFieldPathsPerFrame() {
        let rings = [blob(-200, -150, 320), blob(250, 100, 300), blob(0, 320, 280)]
        perfLog("[perf] field outline paths (3 fields, \(rings.map(\.count)) points)")
        measure("FieldGeometry.path x 3 fields", iterations: 200) {
            for ring in rings { _ = FieldGeometry.path(ring) }
        }
    }

    /// The dot lattice, rebuilt per frame before / translated per frame after.
    @Test @MainActor func costOfDotGridPerFrame() {
        let cache = DotGridPathCache()
        let size = CGSize(width: 1600, height: 1000)
        let spacing = DotGridPathCache.screenSpacing(scale: 1.0)
        perfLog("[perf] dot grid (1600x1000 viewport)")
        measure("lattice build (cold)", iterations: 50) {
            _ = DotGridPathCache().lattice(spacing: spacing, size: size, radius: 1)
        }
        measure("lattice fetch (warm, per frame)", iterations: 50) {
            _ = cache.lattice(spacing: spacing, size: size, radius: 1)
        }
    }

    /// Cursor tracking, which runs on every mouse move (currently twice).
    @Test @MainActor func costOfCursorTrackingPerMove() throws {
        let (store, _) = try makeBoard(notes: 30)
        store.fields = [
            Field(ring: blob(-200, -150, 320), colourIndex: 0, label: "Expensive"),
            Field(ring: blob(250, 100, 300), colourIndex: 1, label: "High impact"),
            Field(ring: blob(0, 320, 280), colourIndex: 2, label: "Later"),
        ]
        perfLog("[perf] cursor tracking")
        var i = 0.0
        measure("updateCursor (one mouse move)", iterations: 200) {
            i += 1
            store.updateCursor(CGPoint(x: 400 + i.truncatingRemainder(dividingBy: 50), y: 300))
        }
    }
}
