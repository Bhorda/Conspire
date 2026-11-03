//
//  ImageAssetTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Conspire

/// A real encoded image, so the codec tests exercise ImageIO rather than a stub.
/// Deliberately not square, which is what makes a mirrored or transposed result
/// detectable.
func makeTestImageData(width: Int, height: Int, alpha: Bool = false) -> Data {
    let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: alphaInfo.rawValue
    )!
    if alpha {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    } else {
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let image = context.makeImage()!

    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

struct ImageCodecTests {

    // MARK: - Caps

    @Test func baseCapNeverExceedsTheOriginal() {
        #expect(ImageCodec.baseCap(nativeLongEdge: 4000) == 1024)
        // A small image is left alone rather than upscaled to the cap.
        #expect(ImageCodec.baseCap(nativeLongEdge: 500) == 500)
    }

    @Test func neededCapTracksTheDisplayedSize() {
        // Shown 800pt across on a retina display wants 1600px.
        #expect(ImageCodec.neededCap(forWorldLongEdge: 800, nativeLongEdge: 4000) == 1600)
    }

    @Test func neededCapIsFlooredAtTheImportCap() {
        // Shrinking an image never proposes a *smaller* asset than import.
        #expect(ImageCodec.neededCap(forWorldLongEdge: 100, nativeLongEdge: 4000) == 1024)
    }

    @Test func neededCapIsCeilingedByTheOriginal() {
        // There is nothing beyond the original's own resolution to recover.
        #expect(ImageCodec.neededCap(forWorldLongEdge: 5000, nativeLongEdge: 1500) == 1500)
    }

    @Test func neededCapIsCeilingedAtTheHardMaximum() {
        #expect(ImageCodec.neededCap(forWorldLongEdge: 9000, nativeLongEdge: 12000) == 4096)
    }

    @Test func resampleIsNotOfferedForAnImageAlreadyAtItsOwnResolution() {
        let needed = ImageCodec.neededCap(forWorldLongEdge: 400, nativeLongEdge: 600)
        #expect(!ImageCodec.resampleWorthwhile(currentCap: 600, neededCap: needed))
    }

    @Test func resampleIsOfferedOnceAnImageOutrunsItsPixels() {
        let needed = ImageCodec.neededCap(forWorldLongEdge: 1200, nativeLongEdge: 4000)
        #expect(ImageCodec.resampleWorthwhile(currentCap: 1024, neededCap: needed))
    }

    @Test func resampleIsNotOfferedForATrivialGain() {
        #expect(!ImageCodec.resampleWorthwhile(currentCap: 1024, neededCap: 1100))
    }

    // MARK: - Decoding

    @Test func pixelSizeIsReadWithoutDecoding() {
        let data = makeTestImageData(width: 400, height: 200)
        #expect(ImageCodec.orientedPixelSize(of: data) == CGSize(width: 400, height: 200))
    }

    @Test func downscaleHitsTheRequestedLongEdgeAndKeepsAspect() {
        let data = makeTestImageData(width: 1200, height: 600)
        let result = ImageCodec.downscaled(data, longEdgeCap: 300)
        #expect(result?.pixelSize == CGSize(width: 300, height: 150))
    }

    @Test func downscaleLeavesASmallImageAlone() {
        let data = makeTestImageData(width: 200, height: 100)
        let result = ImageCodec.downscaled(data, longEdgeCap: 1024)
        #expect(result?.pixelSize == CGSize(width: 200, height: 100))
    }

    /// Re-encoding a transparent image as JPEG would quietly fill the alpha
    /// with black, so an image with alpha has to take the PNG path.
    @Test func transparencySurvivesTheDisplayAsset() {
        let data = makeTestImageData(width: 400, height: 200, alpha: true)
        guard let result = ImageCodec.downscaled(data, longEdgeCap: 200),
              let decoded = ImageCodec.decode(result.data)
        else {
            Issue.record("display asset could not be built")
            return
        }
        #expect(decoded.alphaInfo != .none)
        #expect(decoded.alphaInfo != .noneSkipFirst)
        #expect(decoded.alphaInfo != .noneSkipLast)
    }

    @Test func preparingAnImportFillsInEverythingNeeded() {
        let data = makeTestImageData(width: 2000, height: 1000)
        guard let prepared = ImageCodec.prepare(originalData: data) else {
            Issue.record("prepare returned nil")
            return
        }
        #expect(prepared.nativePixelSize == CGSize(width: 2000, height: 1000))
        #expect(prepared.displayPixelCap == 1024)
        // The original is kept whole, so a later resample has something to work
        // from; the display asset is the smaller one.
        #expect(prepared.originalData == data)
        #expect(prepared.displayData.count < data.count)
    }

    @Test func nonImageDataIsRejectedRatherThanCrashing() {
        let junk = Data("not an image".utf8)
        #expect(ImageCodec.orientedPixelSize(of: junk) == nil)
        #expect(ImageCodec.prepare(originalData: junk) == nil)
    }
}

struct ImageGeometryTests {

    @Test func importRectCentresAndPreservesAspect() {
        let rect = ImageAsset.importRect(
            centeredAt: CGPoint(x: 100, y: 50),
            pixelSize: CGSize(width: 2000, height: 1000),
            longEdge: 360
        )
        #expect(rect.width == 360)
        #expect(rect.height == 180)
        #expect(rect.midX == 100)
        #expect(rect.midY == 50)
    }

    @Test func importRectHandlesAPortraitImage() {
        let rect = ImageAsset.importRect(
            centeredAt: .zero,
            pixelSize: CGSize(width: 500, height: 1000),
            longEdge: 360
        )
        #expect(rect.height == 360)
        #expect(rect.width == 180)
    }

    @Test func resizeKeepsTheOriginalAspect() {
        let asset = ImageAsset(
            worldRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: CGSize(width: 2000, height: 1000),
            displayPixelCap: 1024
        )
        let resized = asset.resized(toCornerWorld: CGPoint(x: 800, y: 999), minimumLongEdge: 60)
        #expect(resized.origin == .zero)
        #expect(abs(resized.width / resized.height - 2) < 0.0001)
    }

    @Test func resizeRefusesToShrinkBelowTheMinimum() {
        let asset = ImageAsset(
            worldRect: CGRect(x: 10, y: 20, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: CGSize(width: 2000, height: 1000),
            displayPixelCap: 1024
        )
        let resized = asset.resized(toCornerWorld: CGPoint(x: 11, y: 21), minimumLongEdge: 60)
        #expect(resized.width >= 60)
        #expect(resized.origin == CGPoint(x: 10, y: 20))
    }

    // MARK: - Pins are normalised, which is the whole point

    private func asset(_ rect: CGRect) -> ImageAsset {
        ImageAsset(
            worldRect: rect,
            zOrder: 0,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: 400
        )
    }

    @Test func normalisedRoundTripsWithWorldPoint() {
        let image = asset(CGRect(x: 100, y: 200, width: 400, height: 200))
        let point = CGPoint(x: 300, y: 250)
        let (u, v) = image.normalised(worldPoint: point)
        #expect(abs(u - 0.5) < 0.0001)
        #expect(abs(v - 0.25) < 0.0001)
        let back = image.worldPoint(u: u, v: v)
        #expect(abs(back.x - point.x) < 0.0001)
        #expect(abs(back.y - point.y) < 0.0001)
    }

    @Test func normalisedClampsToThePicture() {
        let image = asset(CGRect(x: 0, y: 0, width: 400, height: 200))
        let (u, v) = image.normalised(worldPoint: CGPoint(x: -500, y: 9000))
        #expect(u == 0)
        #expect(v == 1)
    }

    @Test func aPinFollowsItsImageThroughAMove() {
        var image = asset(CGRect(x: 0, y: 0, width: 400, height: 200))
        let pin = ImagePin(imageID: image.id, u: 0.25, v: 0.5)
        #expect(image.worldPoint(of: pin) == CGPoint(x: 100, y: 100))

        image.worldRect.origin = CGPoint(x: 1000, y: -40)
        #expect(image.worldPoint(of: pin) == CGPoint(x: 1100, y: 60))
    }

    @Test func aPinFollowsItsImageThroughAResize() {
        var image = asset(CGRect(x: 0, y: 0, width: 400, height: 200))
        let pin = ImagePin(imageID: image.id, u: 0.5, v: 0.5)
        #expect(image.worldPoint(of: pin) == CGPoint(x: 200, y: 100))

        image.worldRect = CGRect(x: 0, y: 0, width: 800, height: 400)
        // Still the middle of the picture, which is the detail it was put on.
        #expect(image.worldPoint(of: pin) == CGPoint(x: 400, y: 200))
    }
}

@MainActor
struct ImageLayerTests {

    private func hostView() -> ImageLayerHostView {
        ImageLayerHostView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    private func asset(_ id: UUID = UUID(), cap: Int = 400) -> ImageAsset {
        ImageAsset(
            id: id,
            worldRect: CGRect(x: 50, y: 60, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: cap
        )
    }

    private func testCGImage() -> CGImage {
        ImageCodec.decode(makeTestImageData(width: 400, height: 200))!
    }

    // MARK: - Orientation
    //
    // The container transform negates y, because world space is y-down and Core
    // Animation is y-up. A shape layer's path does not notice; a layer with
    // `contents` set renders upside down under it. These two tests are the only
    // thing standing between a mirrored photo — obvious — and a mirrored pin,
    // which is not.

    @Test func contentsFlipMirrorsWithinTheLayersOwnBounds() {
        let flip = ImageLayerHostView.contentsFlip(height: 200)
        let bottom = CGPoint(x: 10, y: 0).applying(flip)
        let top = CGPoint(x: 10, y: 200).applying(flip)
        #expect(abs(bottom.y - 200) < 0.0001)
        #expect(abs(top.y - 0) < 0.0001)
        // Horizontal is untouched: this mirrors, it does not rotate.
        #expect(abs(bottom.x - 10) < 0.0001)
    }

    @Test func anImageIsNotMirroredVerticallyOnScreen() {
        let rect = CGRect(x: 0, y: 100, width: 400, height: 200)
        let container = FieldLayerHostView.canvasTransform(pan: .zero, scale: 1, viewHeight: 1000)
        let flip = ImageLayerHostView.contentsFlip(height: rect.height)

        // Core Animation draws the image's top row at the layer's maxY.
        func screenY(local: CGPoint, flipped: Bool) -> CGFloat {
            let inLayer = flipped ? local.applying(flip) : local
            let inWorld = CGPoint(x: rect.minX + inLayer.x, y: rect.minY + inLayer.y)
            return inWorld.applying(container).y
        }
        let topRow = CGPoint(x: 0, y: rect.height)
        let bottomRow = CGPoint(x: 0, y: 0)

        // Larger y is higher on screen in Core Animation.
        #expect(screenY(local: topRow, flipped: true) > screenY(local: bottomRow, flipped: true))
        // And without the flip it would be the wrong way up — so the assertion
        // above is testing something.
        #expect(screenY(local: topRow, flipped: false) < screenY(local: bottomRow, flipped: false))
    }

    // MARK: - Layer bookkeeping

    @Test func layersAreAddedReusedAndRemoved() {
        let view = hostView()
        let first = asset()
        let second = asset()
        let image = testCGImage()
        let both = [first.resourceID: image, second.resourceID: image]

        view.apply(images: [first, second], contents: both, pan: .zero, scale: 1)
        #expect(view.imageLayerCount == 2)
        let identity = view.imageLayerIdentity

        // A second pass with the same images must reuse the layers.
        view.apply(
            images: [first, second], contents: both,
            pan: CGSize(width: 40, height: 40), scale: 1.5
        )
        #expect(view.imageLayerIdentity == identity)

        view.apply(images: [first], contents: [first.resourceID: image], pan: .zero, scale: 1)
        #expect(view.imageLayerCount == 1)
    }

    /// Contents are keyed by resource, so a picture placed twice is two layers
    /// drawing one texture.
    @Test func twoPlacementsOfOnePictureShareItsContents() {
        let view = hostView()
        let resourceID = UUID()
        var first = asset()
        var second = asset()
        first.resourceID = resourceID
        second.resourceID = resourceID
        second.worldRect.origin = CGPoint(x: 900, y: 900)

        view.apply(
            images: [first, second],
            contents: [resourceID: testCGImage()],
            pan: .zero, scale: 1
        )
        #expect(view.imageLayerCount == 2)
    }

    @Test func anImageStillDecodingGetsNoLayer() {
        let view = hostView()
        let pending = asset()
        view.apply(images: [pending], contents: [:], pan: .zero, scale: 1)
        #expect(view.imageLayerCount == 0)
    }

    /// Contents are a GPU texture upload. Panning and zooming must not touch
    /// them — that was the whole reason for moving images off the CPU.
    @Test func contentsAreOnlyAssignedWhenTheDisplayAssetChanges() {
        let view = hostView()
        var sample = asset(cap: 400)
        let image = testCGImage()

        view.apply(images: [sample], contents: [sample.resourceID: image], pan: .zero, scale: 1)
        #expect(view.renderedCap(for: sample.id) == 400)

        // Pan, zoom, move and resize: none of these is a new asset.
        sample.worldRect = CGRect(x: 900, y: 900, width: 800, height: 400)
        view.apply(
            images: [sample], contents: [sample.resourceID: image],
            pan: CGSize(width: 120, height: -60), scale: 2.5
        )
        #expect(view.renderedCap(for: sample.id) == 400)

        // A resample is, and is the only thing that is.
        sample.displayPixelCap = 1600
        view.apply(images: [sample], contents: [sample.resourceID: image], pan: .zero, scale: 1)
        #expect(view.renderedCap(for: sample.id) == 1600)
    }

    @Test func layerGeometryFollowsTheWorldRect() {
        let view = hostView()
        let sample = asset()
        view.apply(
            images: [sample], contents: [sample.resourceID: testCGImage()], pan: .zero, scale: 1
        )
        guard let frame = view.layerFrame(for: sample.id) else {
            Issue.record("no layer")
            return
        }
        #expect(frame.size == sample.worldRect.size)
        #expect(frame.origin == sample.worldRect.origin)
    }
}
