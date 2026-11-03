//
//  WhiteboardStore+Pins.swift
//  Conspire
//

import CoreGraphics
import Foundation
import SwiftData

/// Pins: the points on an image that strings attach to.
///
/// A string never connects to a picture as a whole, only to a pin on it, so
/// "connected to this part of the photo" is the only kind of connection an
/// image can have. Pins exist solely to hold strings — one is created by the
/// string tool at the moment you click, and removed again as soon as nothing
/// is attached to it. There is no pin tool and nothing to tidy up by hand.
extension WhiteboardStore {

    // MARK: - Lookup

    func pin(withID id: UUID?) -> ImagePin? {
        guard let id else { return nil }
        return pins[id]
    }

    func pins(onImage imageID: UUID) -> [ImagePin] {
        pins.values.filter { $0.imageID == imageID }
    }

    /// Screen position of a pin, for drawing and hit-testing at a constant size.
    func pinRootPoint(_ pin: ImagePin) -> CGPoint? {
        guard let asset = image(withID: pin.imageID) else { return nil }
        let world = asset.worldPoint(of: pin)
        return CGPoint(
            x: world.x * canvasScale + pixelSnappedPan.width,
            y: world.y * canvasScale + pixelSnappedPan.height
        )
    }

    /// A pin only shows when it is holding a string, or while you are working
    /// on the image it belongs to — otherwise the picture stays clean.
    func visiblePins() -> [ImagePin] {
        pins.values.filter { pin in
            if linkCount(forPin: pin.id) > 0 { return true }
            return pin.imageID == selectedImageID || pin.imageID == hoveredImageID
        }
    }

    func pin(atRoot point: CGPoint) -> ImagePin? {
        let radius = WhiteboardStyle.pinGrabRadius
        var best: (pin: ImagePin, distance: CGFloat)?
        for pin in visiblePins() {
            guard let root = pinRootPoint(pin) else { continue }
            let distance = hypot(root.x - point.x, root.y - point.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance {
                best = (pin, distance)
            }
        }
        return best?.pin
    }

    // MARK: - Creating one with the string tool

    /// A click on an image while the string tool is up: pin that exact point,
    /// then start or finish the string there.
    func pinAndLink(imageID: UUID, u: CGFloat, v: CGFloat) {
        // Clicking a pin that is already there reuses it, so several strings
        // can meet at one detail rather than stacking coincident pins.
        let pin = existingPin(onImage: imageID, nearU: u, nearV: v)
            ?? ImagePin(imageID: imageID, u: u, v: v)
        let isNew = pins[pin.id] == nil
        if isNew {
            pins[pin.id] = pin
            persistPin(pin)
        }

        if linkDraftSource == nil {
            // Remembered so abandoning the draft takes the pin with it — but
            // only if we made it; one that was already there stays.
            linkDraftCreatedPinID = isNew ? pin.id : nil
            beginLink(from: .pin(pin.id))
        } else {
            commitLink(to: .pin(pin.id))
            // The commit may have been refused — a duplicate, or the same
            // endpoint twice — in which case this pin holds nothing.
            removePinIfOrphaned(pin.id)
        }
    }

    /// A pin on this image within grab distance of the clicked point.
    private func existingPin(onImage imageID: UUID, nearU u: CGFloat, nearV v: CGFloat) -> ImagePin? {
        guard let asset = image(withID: imageID) else { return nil }
        let target = asset.worldPoint(u: u, v: v)
        // Grab distance is a screen measurement, so it has to come back into
        // world units to be compared here.
        let radius = WhiteboardStyle.pinGrabRadius / max(canvasScale, 0.01)
        return pins(onImage: imageID)
            .map { (pin: $0, distance: hypot(
                asset.worldPoint(of: $0).x - target.x,
                asset.worldPoint(of: $0).y - target.y
            )) }
            .filter { $0.distance <= radius }
            .min { $0.distance < $1.distance }?
            .pin
    }

    // MARK: - Dragging

    func beginPinGesture(id: UUID) {
        guard let pin = pins[id] else { return }
        pinGesture = PinGesture(id: id, startU: pin.u, startV: pin.v)
    }

    func updatePinGesture(atRoot point: CGPoint) {
        guard let gesture = pinGesture,
              let pin = pins[gesture.id],
              let asset = image(withID: pin.imageID)
        else { return }
        let normalised = asset.normalised(worldPoint: rootToWorld(point))
        pins[gesture.id]?.u = normalised.u
        pins[gesture.id]?.v = normalised.v
    }

    func endPinGesture() {
        guard let gesture = pinGesture, let pin = pins[gesture.id] else {
            pinGesture = nil
            return
        }
        pinGesture = nil
        guard pin.u != gesture.startU || pin.v != gesture.startV else { return }
        persistPin(pin)
        appendActionLog("pin moved")
    }

    func cancelPinGesture() {
        guard let gesture = pinGesture else { return }
        pins[gesture.id]?.u = gesture.startU
        pins[gesture.id]?.v = gesture.startV
        pinGesture = nil
    }

    // MARK: - Lifecycle

    func linkCount(forPin id: UUID) -> Int {
        links.values.reduce(into: 0) { count, link in
            if link.from == .pin(id) || link.to == .pin(id) { count += 1 }
        }
    }

    /// A pin with nothing attached has no reason to exist.
    func removePinIfOrphaned(_ id: UUID) {
        guard pins[id] != nil, linkCount(forPin: id) == 0 else { return }
        pins.removeValue(forKey: id)
        deletePinEntity(id: id)
    }

    /// Everything pinned to an image goes with it, strings included.
    func removePins(forImage imageID: UUID) {
        let doomed = Set(pins(onImage: imageID).map(\.id))
        guard !doomed.isEmpty else { return }

        // Collect before removing: removeLink mutates `links`.
        let orphaned = links.values.filter { link in
            doomed.contains { link.from == .pin($0) || link.to == .pin($0) }
        }
        for link in orphaned { removeLink(link.id) }
        for id in doomed {
            pins.removeValue(forKey: id)
            deletePinEntity(id: id)
        }
    }

    // MARK: - Persistence

    func loadPinsForActiveBoard() {
        guard let context = persistence?.context, let boardID = activeBoardID else {
            pins = [:]
            return
        }
        let predicate = #Predicate<ImagePinEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<ImagePinEntity>(predicate: predicate))) ?? []
        var loaded: [UUID: ImagePin] = [:]
        let liveImages = Set(images.map(\.id))
        for entity in entities {
            let pin = entity.toPin()
            // A pin whose image is gone is debris; drop it rather than keep a
            // string anchored to nothing.
            guard liveImages.contains(pin.imageID) else {
                context.delete(entity)
                continue
            }
            loaded[pin.id] = pin
        }
        pins = loaded
        try? context.save()
    }

    func persistPin(_ pin: ImagePin) {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        let targetID = pin.id
        let predicate = #Predicate<ImagePinEntity> { $0.id == targetID }
        if let entity = try? context.fetch(FetchDescriptor<ImagePinEntity>(predicate: predicate)).first {
            entity.u = pin.u
            entity.v = pin.v
        } else {
            context.insert(ImagePinEntity(boardID: boardID, pin: pin))
        }
        try? context.save()
    }

    /// Reconciles the whole set after an undo replaced `pins` wholesale.
    func persistAllPins() {
        guard let context = persistence?.context, let boardID = activeBoardID else { return }
        let predicate = #Predicate<ImagePinEntity> { $0.boardID == boardID }
        let entities = (try? context.fetch(FetchDescriptor<ImagePinEntity>(predicate: predicate))) ?? []
        for entity in entities where pins[entity.id] == nil {
            context.delete(entity)
        }
        try? context.save()
        for pin in pins.values { persistPin(pin) }
    }

    func deletePinEntity(id: UUID) {
        guard let context = persistence?.context else { return }
        let targetID = id
        let predicate = #Predicate<ImagePinEntity> { $0.id == targetID }
        if let entity = try? context.fetch(FetchDescriptor<ImagePinEntity>(predicate: predicate)).first {
            context.delete(entity)
            try? context.save()
        }
    }
}
