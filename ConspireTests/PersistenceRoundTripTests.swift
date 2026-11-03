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
    ]

    /// `bootstrap: false` leaves the store exactly as created, so a test can
    /// seed it to look like an older version before running the migration.
    init(bootstrap: Bool = true) throws {
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
    }

    static func makeContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: Schema(schema), configurations: ModelConfiguration(url: url))
    }

    /// What a relaunch sees: a brand new container over the same file.
    func reopen() throws -> ModelContext {
        service.flushPendingSaves()
        return ModelContext(try Self.makeContainer(at: url))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct PersistenceRoundTripTests {

    private func preparedImage() -> PreparedImage {
        ImageCodec.prepare(originalData: makeTestImageData(width: 800, height: 400))!
    }

    /// The one that matters: an image added to a board has to still be there
    /// after the app is restarted. The bytes live in external storage, which is
    /// the part a purely in-memory test would never check.
    @Test func anImagePlacementSurvivesAReopen() throws {
        let temp = try TemporaryStore()
        let prepared = preparedImage()
        let asset = ImageAsset(
            worldRect: CGRect(x: 10, y: 20, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: prepared.nativePixelSize,
            displayPixelCap: prepared.displayPixelCap
        )
        temp.store.images = [asset]
        temp.store.insertImageEntity(
            asset,
            blobs: ImageBlobs(original: prepared.originalData, display: prepared.displayData)
        )

        let reread = try temp.reopen()
        let rows = try reread.fetch(FetchDescriptor<ImageEntity>())

        #expect(rows.count == 1)
        #expect(rows.first?.id == asset.id)
        #expect(rows.first?.displayData.isEmpty == false)
        #expect(rows.first?.originalData.isEmpty == false)
        #expect(rows.first?.toAsset().worldRect == asset.worldRect)
    }

    @Test func movingAnImageIsPersisted() throws {
        let temp = try TemporaryStore()
        let prepared = preparedImage()
        var asset = ImageAsset(
            worldRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: prepared.nativePixelSize,
            displayPixelCap: prepared.displayPixelCap
        )
        temp.store.images = [asset]
        temp.store.insertImageEntity(
            asset,
            blobs: ImageBlobs(original: prepared.originalData, display: prepared.displayData)
        )

        asset.worldRect.origin = CGPoint(x: 500, y: 600)
        temp.store.images = [asset]
        temp.store.persistImage(asset)

        let reread = try temp.reopen()
        let rows = try reread.fetch(FetchDescriptor<ImageEntity>())
        #expect(rows.first?.toAsset().worldRect.origin == CGPoint(x: 500, y: 600))
    }

    @Test func aPinSurvivesAReopen() throws {
        let temp = try TemporaryStore()
        let prepared = preparedImage()
        let asset = ImageAsset(
            worldRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: prepared.nativePixelSize,
            displayPixelCap: prepared.displayPixelCap
        )
        temp.store.images = [asset]
        temp.store.insertImageEntity(
            asset,
            blobs: ImageBlobs(original: prepared.originalData, display: prepared.displayData)
        )
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
        let prepared = preparedImage()
        let asset = ImageAsset(
            worldRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: prepared.nativePixelSize,
            displayPixelCap: prepared.displayPixelCap
        )
        temp.store.images = [asset]
        temp.store.insertImageEntity(
            asset,
            blobs: ImageBlobs(original: prepared.originalData, display: prepared.displayData)
        )
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
