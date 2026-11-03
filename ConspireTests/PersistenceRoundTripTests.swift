//
//  PersistenceRoundTripTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Conspire

/// A real file-backed store in a temp directory.
///
/// Deliberately not `isStoredInMemoryOnly`: images are held in
/// `@Attribute(.externalStorage)` blobs, which an in-memory store does not
/// exercise the same way, and the question these tests answer is whether the
/// bytes are on disk after a relaunch.
@MainActor
final class TemporaryStore {
    let directory: URL
    let url: URL
    private(set) var container: ModelContainer
    private(set) var service: WhiteboardPersistenceService
    private(set) var store: WhiteboardStore

    static let schema: [any PersistentModel.Type] = [
        ProjectEntity.self,
        BoardEntity.self, NoteEntity.self, NoteGroupEntity.self,
        LinkEntity.self, FieldEntity.self, ImageEntity.self, ImagePinEntity.self,
        ImageResourceEntity.self, TextResourceEntity.self,
    ]

    /// `bootstrap: false` leaves the store exactly as created, so a test can
    /// seed it to look like an older version before running the migration.
    init(bootstrap: Bool = true) throws {
        Self.sweepOldDirectories()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "conspire-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "Test.store")
        container = try Self.makeContainer(at: url)
        service = WhiteboardPersistenceService()
        service.configure(context: ModelContext(container))
        if bootstrap { service.bootstrap() }
        store = WhiteboardStore()
        store.persistence = service
        store.activeBoardID = service.activeBoardID
        store.activeProjectID = service.activeProjectID
    }

    /// Imports a picture the way the app does: a resource in the project, then
    /// a placement of it on the open board.
    @discardableResult
    func placeImage(
        at worldCenter: CGPoint = CGPoint(x: 200, y: 100),
        width: Int = 800,
        height: Int = 400
    ) -> ImageAsset? {
        let prepared = ImageCodec.prepare(
            originalData: makeTestImageData(width: width, height: height)
        )!
        guard let resource = store.addImageResource(prepared, name: "Test") else { return nil }
        store.placeImageResource(resource.id, atWorld: worldCenter)
        return store.images.last
    }

    static func makeContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: Schema(schema), configurations: ModelConfiguration(url: url))
    }

    /// What a relaunch sees: a brand new container over the same file.
    func reopen() throws -> ModelContext {
        service.flushPendingSaves()
        return ModelContext(try Self.makeContainer(at: url))
    }

    /// Deliberately no cleanup in `deinit`. SwiftData faults rows lazily, so
    /// pulling the file out from under a container that is still alive gives
    /// "disk I/O error" from an unrelated test. Stale directories are swept on
    /// the way in instead.
    private static func sweepOldDirectories() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let cutoff = Date().addingTimeInterval(-3600)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("conspire-test-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

@MainActor
struct PersistenceRoundTripTests {

    /// The one that matters: an image added to a board has to still be there
    /// after the app is restarted. The bytes live in external storage, which is
    /// the part a purely in-memory test would never check.
    @Test func anImagePlacementAndItsResourceSurviveAReopen() throws {
        let temp = try TemporaryStore()
        let asset = temp.placeImage(at: CGPoint(x: 210, y: 120))!

        let reread = try temp.reopen()
        let placements = try reread.fetch(FetchDescriptor<ImageEntity>())
        let resources = try reread.fetch(FetchDescriptor<ImageResourceEntity>())

        #expect(placements.count == 1)
        #expect(placements.first?.id == asset.id)
        #expect(placements.first?.resourceID == asset.resourceID)
        // The bytes are on the resource now, not on the placement.
        #expect(resources.count == 1)
        #expect(resources.first?.displayData.isEmpty == false)
        #expect(resources.first?.originalData.isEmpty == false)
        #expect(resources.first?.thumbnailData.isEmpty == false)
        #expect(placements.first?.toAsset().worldRect == asset.worldRect)
    }

    /// The point of the split: a picture on two boards is one set of bytes.
    @Test func twoPlacementsShareOneResource() throws {
        let temp = try TemporaryStore()
        let prepared = ImageCodec.prepare(originalData: makeTestImageData(width: 800, height: 400))!
        let resource = temp.store.addImageResource(prepared, name: "Shared")!
        temp.store.placeImageResource(resource.id, atWorld: CGPoint(x: 100, y: 100))
        temp.store.placeImageResource(resource.id, atWorld: CGPoint(x: 600, y: 400))

        let reread = try temp.reopen()
        #expect(try reread.fetch(FetchDescriptor<ImageEntity>()).count == 2)
        #expect(try reread.fetch(FetchDescriptor<ImageResourceEntity>()).count == 1)
        // And one decode, keyed by resource.
        #expect(temp.store.imageContents.count == 1)
    }

    @Test func movingAnImageIsPersisted() throws {
        let temp = try TemporaryStore()
        var asset = temp.placeImage(at: CGPoint(x: 0, y: 0))!

        asset.worldRect.origin = CGPoint(x: 500, y: 600)
        temp.store.images = [asset]
        temp.store.persistImage(asset)

        let reread = try temp.reopen()
        let rows = try reread.fetch(FetchDescriptor<ImageEntity>())
        #expect(rows.first?.toAsset().worldRect.origin == CGPoint(x: 500, y: 600))
    }

    @Test func aPinSurvivesAReopen() throws {
        let temp = try TemporaryStore()
        let asset = temp.placeImage()!
        temp.store.placementMode = .string
        temp.store.handleImageTap(asset.id, atNormalised: (u: 0.25, v: 0.75))
        temp.store.commitLink(to: .note(UUID()))

        let reread = try temp.reopen()
        let pins = try reread.fetch(FetchDescriptor<ImagePinEntity>())
        #expect(pins.count == 1)
        #expect(abs((pins.first?.u ?? 0) - 0.25) < 0.0001)
    }

    /// A string anchored to a pin has to read back as a pin, not fall through
    /// to the legacy note/stack flag.
    @Test func aPinnedStringSurvivesAReopen() throws {
        let temp = try TemporaryStore()
        let asset = temp.placeImage()!
        temp.store.placementMode = .string
        temp.store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        let pinID = temp.store.pins.values.first!.id
        temp.store.commitLink(to: .note(UUID()))

        let reread = try temp.reopen()
        let links = try reread.fetch(FetchDescriptor<LinkEntity>())
        #expect(links.count == 1)
        #expect(links.first?.toLink().from == .pin(pinID))
    }

    @Test func aFieldSurvivesAReopen() throws {
        let temp = try TemporaryStore()
        temp.store.placementMode = .field
        temp.store.fieldDraftStroke = (0..<48).map { i in
            let a = CGFloat(i) / 48 * .pi * 2
            return CGPoint(x: 200 + cos(a) * 60, y: 200 + sin(a) * 60)
        }
        temp.store.endFieldStroke()
        #expect(temp.store.fields.count == 1)

        let reread = try temp.reopen()
        let rows = try reread.fetch(FetchDescriptor<FieldEntity>())
        #expect(rows.count == 1)
        #expect(rows.first?.toField().ring.count ?? 0 > 2)
    }
}
