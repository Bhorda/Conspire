//
//  ImagePinTests.swift
//  ConspireTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Conspire

@MainActor
struct ImagePinTests {

    private func storeWithImage() -> (WhiteboardStore, ImageAsset) {
        let store = WhiteboardStore()
        let asset = ImageAsset(
            worldRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            zOrder: 0,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: 400
        )
        store.images = [asset]
        return (store, asset)
    }

    // MARK: - Anchoring

    @Test func aStringEndpointResolvesToThePinnedPointNotTheImageCentre() {
        let (store, asset) = storeWithImage()
        let pin = ImagePin(imageID: asset.id, u: 0.25, v: 0.75)
        store.pins = [pin.id: pin]

        // The centre would be (200, 100); the pin is not there.
        #expect(store.anchorPoint(for: .pin(pin.id)) == CGPoint(x: 100, y: 150))
    }

    @Test func aPinAnchorMovesWithItsImage() {
        let (store, asset) = storeWithImage()
        let pin = ImagePin(imageID: asset.id, u: 0.5, v: 0.5)
        store.pins = [pin.id: pin]
        store.images[0].worldRect.origin = CGPoint(x: 1000, y: 1000)

        #expect(store.anchorPoint(for: .pin(pin.id)) == CGPoint(x: 1200, y: 1100))
    }

    @Test func aPinWhoseImageIsGoneAnchorsNowhere() {
        let store = WhiteboardStore()
        let pin = ImagePin(imageID: UUID(), u: 0.5, v: 0.5)
        store.pins = [pin.id: pin]
        #expect(store.anchorPoint(for: .pin(pin.id)) == nil)
    }

    // MARK: - Making one with the string tool

    @Test func clickingAnImageInStringModeStartsAStringFromThatPoint() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.2, v: 0.4))

        #expect(store.pins.count == 1)
        guard let pin = store.pins.values.first else { return }
        #expect(abs(pin.u - 0.2) < 0.0001)
        #expect(abs(pin.v - 0.4) < 0.0001)
        #expect(store.linkDraftSource == .pin(pin.id))
    }

    @Test func clickingAnImageInHandModeSelectsItInsteadOfPinning() {
        let (store, asset) = storeWithImage()
        store.handleImageTap(asset.id, atNormalised: (u: 0.2, v: 0.4))

        #expect(store.pins.isEmpty)
        #expect(store.selectedImageID == asset.id)
    }

    @Test func aStringCanRunFromAPointInAnImageToANote() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string
        let noteID = UUID()

        store.handleImageTap(asset.id, atNormalised: (u: 0.1, v: 0.1))
        guard let pin = store.pins.values.first else {
            Issue.record("no pin was created")
            return
        }
        store.commitLink(to: .note(noteID))

        #expect(store.links.count == 1)
        #expect(store.pins.count == 1)
        guard let link = store.links.values.first else { return }
        #expect(link.connects(.pin(pin.id), .note(noteID)))
    }

    @Test func aStringCanRunBetweenPointsInTwoImages() {
        let (store, first) = storeWithImage()
        let second = ImageAsset(
            worldRect: CGRect(x: 600, y: 0, width: 400, height: 200),
            zOrder: 1,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: 400
        )
        store.images.append(second)
        store.placementMode = .string

        store.handleImageTap(first.id, atNormalised: (u: 0.9, v: 0.5))
        store.handleImageTap(second.id, atNormalised: (u: 0.1, v: 0.5))

        #expect(store.links.count == 1)
        #expect(store.pins.count == 2)
    }

    /// Several strings meeting at one detail should share its pin rather than
    /// stacking invisible duplicates on the same spot.
    @Test func clickingAnExistingPinReusesIt() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))
        #expect(store.pins.count == 1)

        // Near enough to be the same detail.
        store.handleImageTap(asset.id, atNormalised: (u: 0.505, v: 0.5))
        store.commitLink(to: .note(UUID()))

        #expect(store.pins.count == 1)
        #expect(store.links.count == 2)
    }

    @Test func clickingWellAwayFromAPinMakesANewOne() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.1, v: 0.1))
        store.commitLink(to: .note(UUID()))
        store.handleImageTap(asset.id, atNormalised: (u: 0.9, v: 0.9))
        store.commitLink(to: .note(UUID()))

        #expect(store.pins.count == 2)
    }

    // MARK: - Pins exist only to hold strings

    @Test func abandoningADraftTakesThePinItCreated() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        #expect(store.pins.count == 1)

        store.cancelLinkDraft()
        #expect(store.pins.isEmpty)
    }

    @Test func escapeDuringADraftTakesThePinWithIt() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        #expect(store.handleEscape())
        #expect(store.pins.isEmpty)
    }

    @Test func abandoningADraftLeavesAPinThatWasAlreadyThere() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))
        #expect(store.pins.count == 1)

        // Start a second string from the same pin, then give up on it.
        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        store.cancelLinkDraft()

        #expect(store.pins.count == 1)
        #expect(store.links.count == 1)
    }

    @Test func deletingTheLastStringOnAPinRemovesThePin() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))
        guard let link = store.links.values.first else {
            Issue.record("no link")
            return
        }
        store.removeLink(link.id)

        #expect(store.pins.isEmpty)
    }

    @Test func deletingOneOfTwoStringsKeepsThePin() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))
        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))
        #expect(store.links.count == 2)

        store.removeLink(store.links.values.first!.id)

        #expect(store.pins.count == 1)
        #expect(store.links.count == 1)
    }

    @Test func deletingAnImageTakesItsPinsAndStrings() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string

        store.handleImageTap(asset.id, atNormalised: (u: 0.2, v: 0.2))
        store.commitLink(to: .note(UUID()))
        store.handleImageTap(asset.id, atNormalised: (u: 0.8, v: 0.8))
        store.commitLink(to: .note(UUID()))
        #expect(store.pins.count == 2)
        #expect(store.links.count == 2)

        store.deleteImage(asset.id)

        #expect(store.images.isEmpty)
        #expect(store.pins.isEmpty)
        #expect(store.links.isEmpty)
    }

    @Test func deletingAnImageLeavesAnotherImagesPinsAlone() {
        let (store, first) = storeWithImage()
        let second = ImageAsset(
            worldRect: CGRect(x: 600, y: 0, width: 400, height: 200),
            zOrder: 1,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: 400
        )
        store.images.append(second)
        store.placementMode = .string

        store.handleImageTap(first.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))
        store.handleImageTap(second.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))

        store.deleteImage(first.id)

        #expect(store.pins.count == 1)
        #expect(store.links.count == 1)
        #expect(store.pins.values.first?.imageID == second.id)
    }

    // MARK: - Visibility and grabbing

    @Test func aPinHoldingNoStringShowsOnlyWhileItsImageIsBeingWorkedOn() {
        let (store, asset) = storeWithImage()
        let pin = ImagePin(imageID: asset.id, u: 0.5, v: 0.5)
        store.pins = [pin.id: pin]

        #expect(store.visiblePins().isEmpty)

        store.hoveredImageID = asset.id
        #expect(store.visiblePins().count == 1)

        store.hoveredImageID = nil
        store.selectedImageID = asset.id
        #expect(store.visiblePins().count == 1)
    }

    @Test func aPinHoldingAStringAlwaysShows() {
        let (store, asset) = storeWithImage()
        store.placementMode = .string
        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        store.commitLink(to: .note(UUID()))
        store.selectedImageID = nil
        store.hoveredImageID = nil

        #expect(store.visiblePins().count == 1)
    }

    @Test func grabbingFindsThePinUnderThePointer() {
        let (store, asset) = storeWithImage()
        store.selectedImageID = asset.id
        let pin = ImagePin(imageID: asset.id, u: 0.5, v: 0.5)
        store.pins = [pin.id: pin]

        // Scale 1 and no pan, so world (200, 100) is screen (200, 100).
        #expect(store.pin(atRoot: CGPoint(x: 203, y: 102))?.id == pin.id)
        #expect(store.pin(atRoot: CGPoint(x: 300, y: 100)) == nil)
    }

    // MARK: - Dragging a pin

    @Test func draggingAPinRepositionsItOnTheImage() {
        let (store, asset) = storeWithImage()
        let pin = ImagePin(imageID: asset.id, u: 0.5, v: 0.5)
        store.pins = [pin.id: pin]

        store.beginPinGesture(id: pin.id)
        store.updatePinGesture(atRoot: CGPoint(x: 100, y: 50))
        store.endPinGesture()

        #expect(abs((store.pins[pin.id]?.u ?? 0) - 0.25) < 0.0001)
        #expect(abs((store.pins[pin.id]?.v ?? 0) - 0.25) < 0.0001)
    }

    /// The pin marks a detail, and a detail outside the frame means nothing, so
    /// dragging past the edge slides it along the boundary instead of following
    /// the pointer out.
    @Test func draggingPastTheEdgeSlidesThePinAlongTheBoundary() {
        let (store, asset) = storeWithImage()
        let pin = ImagePin(imageID: asset.id, u: 0.5, v: 0.5)
        store.pins = [pin.id: pin]

        store.beginPinGesture(id: pin.id)
        // 10pt past the left edge — inside the 18pt forgiveness.
        store.updatePinGesture(atRoot: CGPoint(x: -10, y: 100))

        #expect(store.pins[pin.id]?.u == 0)
        #expect(abs((store.pins[pin.id]?.v ?? 0) - 0.5) < 0.0001)
        #expect(!store.pinDragWillDetach)

        store.endPinGesture()
        #expect(store.pins[pin.id] != nil)
    }

    // MARK: - Dragging a pin off the picture detaches it

    private func pinnedAndLinked(_ store: WhiteboardStore, _ asset: ImageAsset) -> UUID {
        store.placementMode = .string
        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        let id = store.pins.values.first!.id
        store.commitLink(to: .note(UUID()))
        store.placementMode = .hand
        return id
    }

    @Test func releasingAPinClearOfThePictureTakesItAndItsString() {
        let (store, asset) = storeWithImage()
        let id = pinnedAndLinked(store, asset)

        store.beginPinGesture(id: id)
        store.updatePinGesture(atRoot: CGPoint(x: -200, y: 100))
        #expect(store.pinDragWillDetach)
        store.endPinGesture()

        #expect(store.pins.isEmpty)
        #expect(store.links.isEmpty)
        #expect(!store.pinDragWillDetach)
    }

    @Test func comingBackOverThePictureCallsOffTheDetach() {
        let (store, asset) = storeWithImage()
        let id = pinnedAndLinked(store, asset)

        store.beginPinGesture(id: id)
        store.updatePinGesture(atRoot: CGPoint(x: -500, y: 100))
        #expect(store.pinDragWillDetach)
        store.updatePinGesture(atRoot: CGPoint(x: 300, y: 100))
        #expect(!store.pinDragWillDetach)
        store.endPinGesture()

        #expect(store.pins.count == 1)
        #expect(store.links.count == 1)
        #expect(abs((store.pins[id]?.u ?? 0) - 0.75) < 0.0001)
    }

    @Test func escapeDuringADetachDragPutsThePinBack() {
        let (store, asset) = storeWithImage()
        let id = pinnedAndLinked(store, asset)

        store.beginPinGesture(id: id)
        store.updatePinGesture(atRoot: CGPoint(x: -500, y: -500))
        #expect(store.handleEscape())

        #expect(store.pins[id]?.u == 0.5)
        #expect(store.pins[id]?.v == 0.5)
        #expect(store.links.count == 1)
        #expect(!store.pinDragWillDetach)
    }

    /// Forgiveness is a screen measurement, so zooming out must not make the
    /// edge of a picture a hair trigger in world terms.
    @Test func detachForgivenessHoldsAtAnyZoom() {
        let (store, asset) = storeWithImage()
        let id = pinnedAndLinked(store, asset)
        store.canvasScale = 0.25

        store.beginPinGesture(id: id)
        // Root (-10, 25) is world (-40, 100) at this zoom: 40 world units past
        // the edge, which would detach at 1:1, but only 10pt on screen here.
        store.updatePinGesture(atRoot: CGPoint(x: -10, y: 25))
        #expect(!store.pinDragWillDetach)
        store.endPinGesture()

        #expect(store.pins.count == 1)
    }

    // MARK: - The settle animation must not fight a live drag

    /// Only a pinned string skips the settle animation. A note-to-note string
    /// keeps it, because notes ease into place and their strings should too.
    @Test func onlyPinnedStringsSkipTheSettleAnimation() {
        let pinID = UUID()
        #expect(Link(from: .pin(pinID), to: .note(UUID()), colorIndex: 0).touchesPin)
        #expect(Link(from: .note(UUID()), to: .pin(pinID), colorIndex: 0).touchesPin)
        #expect(Link(from: .pin(pinID), to: .pin(UUID()), colorIndex: 0).touchesPin)
        #expect(!Link(from: .note(UUID()), to: .note(UUID()), colorIndex: 0).touchesPin)
        #expect(!Link(from: .note(UUID()), to: .stack(UUID()), colorIndex: 0).touchesPin)
    }

    /// The reason the animation had to go: an image is a Core Animation layer
    /// with actions disabled, so it moves instantly while an eased string
    /// endpoint arrives 200ms later — the string visibly comes off the pin.
    @Test func aStringEndpointKeepsUpWithTheImageMidDrag() {
        let (store, first) = storeWithImage()
        let second = ImageAsset(
            worldRect: CGRect(x: 900, y: 0, width: 400, height: 200),
            zOrder: 1,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: 400
        )
        store.images.append(second)

        // Both ends on pictures, so the whole curve resolves.
        store.placementMode = .string
        store.handleImageTap(first.id, atNormalised: (u: 0.5, v: 0.5))
        let movingPin = store.pins.values.first!.id
        store.handleImageTap(second.id, atNormalised: (u: 0.5, v: 0.5))
        store.placementMode = .hand
        guard let link = store.links.values.first else {
            Issue.record("no link")
            return
        }
        #expect(store.curveGeometry(for: link)?.a == CGPoint(x: 200, y: 100))

        store.beginImageMove(id: first.id, atWorld: CGPoint(x: 0, y: 0))
        store.updateImageGesture(atWorld: CGPoint(x: 500, y: 300))

        // The picture's centre is now (700, 400), and the string end with it.
        #expect(store.anchorPoint(for: .pin(movingPin)) == CGPoint(x: 700, y: 400))
        #expect(store.curveGeometry(for: link)?.a == CGPoint(x: 700, y: 400))
    }

    @Test func escapeDuringAPinDragPutsItBack() {
        let (store, asset) = storeWithImage()
        let pin = ImagePin(imageID: asset.id, u: 0.5, v: 0.5)
        store.pins = [pin.id: pin]

        store.beginPinGesture(id: pin.id)
        store.updatePinGesture(atRoot: CGPoint(x: 10, y: 10))
        #expect(store.handleEscape())

        #expect(store.pins[pin.id]?.u == 0.5)
        #expect(store.pins[pin.id]?.v == 0.5)
        #expect(store.pinGesture == nil)
    }
}

@MainActor
struct ImageStoreTests {

    private func storeWithImage(
        rect: CGRect = CGRect(x: 0, y: 0, width: 400, height: 200)
    ) -> (WhiteboardStore, ImageAsset) {
        let store = WhiteboardStore()
        let asset = ImageAsset(
            worldRect: rect,
            zOrder: 0,
            nativePixelSize: CGSize(width: 4000, height: 2000),
            displayPixelCap: 1024
        )
        store.images = [asset]
        return (store, asset)
    }

    @Test func movingAnImageKeepsItsSize() {
        let (store, asset) = storeWithImage()
        store.beginImageMove(id: asset.id, atWorld: CGPoint(x: 10, y: 10))
        store.updateImageGesture(atWorld: CGPoint(x: 110, y: 60))
        store.endImageGesture()

        #expect(store.images[0].worldRect == CGRect(x: 100, y: 50, width: 400, height: 200))
    }

    @Test func escapeDuringAMovePutsTheImageBack() {
        let (store, asset) = storeWithImage()
        store.beginImageMove(id: asset.id, atWorld: CGPoint(x: 10, y: 10))
        store.updateImageGesture(atWorld: CGPoint(x: 900, y: 900))
        #expect(store.handleEscape())

        #expect(store.images[0].worldRect.origin == .zero)
        #expect(store.imageGesture == nil)
    }

    @Test func topmostImageWinsAHit() {
        let (store, lower) = storeWithImage()
        var upper = lower
        upper = ImageAsset(
            worldRect: CGRect(x: 100, y: 50, width: 400, height: 200),
            zOrder: 5,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: 400
        )
        store.images.append(upper)

        #expect(store.image(atWorld: CGPoint(x: 200, y: 100))?.id == upper.id)
        // Only the lower one covers this point.
        #expect(store.image(atWorld: CGPoint(x: 20, y: 20))?.id == lower.id)
        #expect(store.image(atWorld: CGPoint(x: 5000, y: 5000)) == nil)
    }

    @Test func bringToFrontPutsAnImageOnTop() {
        let (store, first) = storeWithImage()
        let second = ImageAsset(
            worldRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            zOrder: 9,
            nativePixelSize: CGSize(width: 400, height: 200),
            displayPixelCap: 400
        )
        store.images.append(second)

        store.bringImageToFront(first.id)

        let top = store.images.max { $0.zOrder < $1.zOrder }
        #expect(top?.id == first.id)
    }

    @Test func selectingAnImageClearsAFieldSelectionAndViceVersa() {
        let (store, asset) = storeWithImage()
        let field = Field(
            ring: (0..<40).map { i in
                let a = CGFloat(i) / 40 * .pi * 2
                return CGPoint(x: cos(a) * 50, y: sin(a) * 50)
            },
            colourIndex: 0,
            label: "A"
        )
        store.fields = [field]

        store.selectField(field.id)
        store.handleImageTap(asset.id, atNormalised: (u: 0.5, v: 0.5))
        #expect(store.selectedImageID == asset.id)
        #expect(store.selectedFieldID == nil)

        store.selectField(field.id)
        #expect(store.selectedImageID == nil)
    }

    @Test func escapeDeselectsAnImage() {
        let (store, asset) = storeWithImage()
        store.selectImage(asset.id)
        #expect(store.handleEscape())
        #expect(store.selectedImageID == nil)
    }

    // MARK: - Resample

    @Test func resampleIsOfferedOnlyOnceTheImageIsBigEnoughToNeedIt() {
        let (store, _) = storeWithImage()
        // 400pt of a 4000px original at 1:1 is well within the 1024px asset.
        #expect(!store.canResampleImage(store.images[0]))

        store.images[0].worldRect = CGRect(x: 0, y: 0, width: 1600, height: 800)
        #expect(store.canResampleImage(store.images[0]))
    }

    /// Zoom counts: an image shown small but zoomed far in is just as short of
    /// pixels as a large one at 1:1.
    @Test func resampleAccountsForTheCanvasZoom() {
        let (store, _) = storeWithImage()
        #expect(!store.canResampleImage(store.images[0]))

        store.canvasScale = 4
        #expect(store.canResampleImage(store.images[0]))
    }

    @Test func aSmallOriginalIsNeverWorthResampling() {
        let store = WhiteboardStore()
        store.images = [
            ImageAsset(
                worldRect: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                zOrder: 0,
                nativePixelSize: CGSize(width: 400, height: 200),
                displayPixelCap: 400
            )
        ]
        // Blown up far past its own resolution, but there is nothing to recover.
        #expect(!store.canResampleImage(store.images[0]))
    }
}
