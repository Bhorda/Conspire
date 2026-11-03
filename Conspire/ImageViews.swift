//
//  ImageViews.swift
//  Conspire
//

import AppKit
import CoreGraphics
import SwiftUI

/// Images as Core Animation layers, for the same reason fields are.
///
/// A decoded `CGImage` handed to a `CALayer` is uploaded to the GPU once.
/// Panning and zooming are then a single transform on the container, the GPU
/// resamples, and nothing is rasterised per frame. Moving or resizing an image
/// only changes layer geometry, so unlike a field's ring there is not even a
/// path to rebuild.
struct ImageLayerView: NSViewRepresentable {
    @ObservedObject var store: WhiteboardStore

    func makeNSView(context: Context) -> ImageLayerHostView {
        ImageLayerHostView()
    }

    func updateNSView(_ view: ImageLayerHostView, context: Context) {
        view.apply(
            images: store.images,
            contents: store.imageContents,
            pan: store.pixelSnappedPan,
            scale: store.canvasScale
        )
    }
}

final class ImageLayerHostView: NSView {
    private let container = CALayer()
    private var layers: [UUID: CALayer] = [:]
    /// Display cap each layer's contents were set from. Contents only ever
    /// change on import or resample, and the cap is exactly what changes then,
    /// so this is the whole invalidation rule.
    private var renderedCaps: [UUID: Int] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        container.anchorPoint = .zero
        container.position = .zero
        container.masksToBounds = false
        layer?.addSublayer(container)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// Purely decorative; interaction is `ImageInteractionLayer`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Undoes the container's y-flip for this one layer.
    ///
    /// `FieldLayerHostView.canvasTransform` negates y, because world space is
    /// y-down and Core Animation is y-up. A shape layer's path does not care,
    /// but a layer with `contents` set would render upside down under it. The
    /// flip is about the layer's own bounds, so it mirrors in place.
    static func contentsFlip(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: height).scaledBy(x: 1, y: -1)
    }

    func apply(images: [ImageAsset], contents: [UUID: CGImage], pan: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        container.bounds = CGRect(origin: .zero, size: bounds.size)
        container.setAffineTransform(
            FieldLayerHostView.canvasTransform(pan: pan, scale: scale, viewHeight: bounds.height)
        )

        // The GPU resamples the texture at any zoom, so this is the screen's
        // density and nothing more — no zoom-dependent re-rasterisation.
        let density = window?.backingScaleFactor ?? 2

        var live = Set<UUID>()
        for asset in images {
            // Keyed by resource, so a picture placed on two boards is one
            // texture. Decoding happens off the main actor; a placement with
            // no contents yet simply has no layer until they arrive.
            guard let image = contents[asset.resourceID] else { continue }
            live.insert(asset.id)

            let imageLayer = layers[asset.id] ?? makeLayer(for: asset.id)
            if renderedCaps[asset.id] != asset.displayPixelCap {
                imageLayer.contents = image
                renderedCaps[asset.id] = asset.displayPixelCap
            }
            imageLayer.bounds = CGRect(origin: .zero, size: asset.worldRect.size)
            imageLayer.position = asset.worldRect.origin
            imageLayer.setAffineTransform(Self.contentsFlip(height: asset.worldRect.height))
            if imageLayer.contentsScale != density { imageLayer.contentsScale = density }
            if imageLayer.zPosition != CGFloat(asset.zOrder) {
                imageLayer.zPosition = CGFloat(asset.zOrder)
            }
        }

        for (id, imageLayer) in layers where !live.contains(id) {
            imageLayer.removeFromSuperlayer()
            layers.removeValue(forKey: id)
            renderedCaps.removeValue(forKey: id)
        }
    }

    private func makeLayer(for id: UUID) -> CALayer {
        let imageLayer = CALayer()
        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        imageLayer.contentsGravity = .resize
        imageLayer.masksToBounds = true
        container.addSublayer(imageLayer)
        layers[id] = imageLayer
        return imageLayer
    }

    // MARK: - Test visibility

    var imageLayerCount: Int { layers.count }
    var imageLayerIdentity: Set<ObjectIdentifier> { Set(layers.values.map(ObjectIdentifier.init)) }
    func renderedCap(for id: UUID) -> Int? { renderedCaps[id] }
    func layerFrame(for id: UUID) -> CGRect? { layers[id]?.frame }
}

// MARK: - Interaction

/// Select, move, resize and the context menu.
///
/// Deliberately in screen space rather than inside the canvas transform: the
/// selection outline and the resize handle then keep a constant size at any
/// zoom, and the hit areas, the outline and the handle all live in one place.
/// The views themselves hold no content — the pixels come from the layer behind.
struct ImageInteractionLayer: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.images) { asset in
                ImageControlView(store: store, asset: asset)
            }
        }
    }
}

private struct ImageControlView: View {
    @ObservedObject var store: WhiteboardStore
    let asset: ImageAsset

    private var rootRect: CGRect {
        let scale = store.canvasScale
        let pan = store.pixelSnappedPan
        return CGRect(
            x: asset.worldRect.minX * scale + pan.width,
            y: asset.worldRect.minY * scale + pan.height,
            width: asset.worldRect.width * scale,
            height: asset.worldRect.height * scale
        )
    }

    private var isSelected: Bool { store.selectedImageID == asset.id }
    private var isHovered: Bool { store.hoveredImageID == asset.id }

    var body: some View {
        let rect = rootRect
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onTapGesture { local in
                    // Local coordinates inside the image's own frame are the
                    // normalised position directly — no world round trip, and
                    // exact at any zoom.
                    store.handleImageTap(
                        asset.id,
                        atNormalised: (
                            u: rect.width > 0 ? local.x / rect.width : 0,
                            v: rect.height > 0 ? local.y / rect.height : 0
                        )
                    )
                }

            if isSelected {
                resizeHandle
            }
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(
                        WhiteboardStyle.imageSelectionColor,
                        lineWidth: WhiteboardStyle.imageSelectionWidth
                    )
            } else if isHovered {
                Rectangle()
                    .strokeBorder(WhiteboardStyle.imageSelectionColor.opacity(0.35), lineWidth: 1)
            }
        }
        // Hover and the context menu go on the framed content, *before*
        // `.position`. A positioned view fills its parent for layout, so a
        // modifier applied after this line would attach to the whole viewport:
        // the menu would open on a right-click anywhere, and every pin would
        // count as hovered all the time.
        .onHover { inside in
            if inside {
                store.hoveredImageID = asset.id
            } else if store.hoveredImageID == asset.id {
                store.hoveredImageID = nil
            }
        }
        .contextMenu { contextMenu }
        .position(x: rect.midX, y: rect.midY)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(WhiteboardStyle.imageSelectionColor)
            .overlay(Rectangle().strokeBorder(.white, lineWidth: 1))
            .frame(
                width: WhiteboardStyle.imageResizeHandleSize,
                height: WhiteboardStyle.imageResizeHandleSize
            )
            // Straddles the corner, so it is grabbable from outside the image too.
            .offset(
                x: WhiteboardStyle.imageResizeHandleSize / 2,
                y: WhiteboardStyle.imageResizeHandleSize / 2
            )
            .gesture(resizeGesture)
    }

    @ViewBuilder
    private var contextMenu: some View {
        // Absent rather than disabled when it would do nothing — including for
        // an image already shown at its original resolution.
        if store.canResampleImage(asset) {
            Button("Resample for Current Size") { store.resampleImage(asset.id) }
        }
        Button("Bring to Front") { store.bringImageToFront(asset.id) }
        Divider()
        Button("Delete Image") { store.deleteImage(asset.id) }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("root"))
            .onChanged { value in
                if store.imageGesture == nil {
                    store.beginImageMove(
                        id: asset.id, atWorld: store.rootToWorld(value.startLocation)
                    )
                }
                store.updateImageGesture(atWorld: store.rootToWorld(value.location))
            }
            .onEnded { _ in store.endImageGesture() }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
            .onChanged { value in
                if store.imageGesture == nil { store.beginImageResize(id: asset.id) }
                store.updateImageGesture(atWorld: store.rootToWorld(value.location))
            }
            .onEnded { _ in store.endImageGesture() }
    }
}

// MARK: - Pins

/// Pins, drawn in screen space so they stay the same size at any zoom —
/// correct for a pin, and it keeps them out of the canvas transform.
struct PinOverlayView: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            let radius = WhiteboardStyle.pinRadius
            let detaching = store.pinDragWillDetach ? store.pinGesture?.id : nil
            for pin in store.visiblePins() {
                guard let root = store.pinRootPoint(pin) else { continue }
                let willDetach = pin.id == detaching
                // Grows and turns red while it is being pulled off, so letting
                // go is never a surprise.
                let r = willDetach ? radius * 1.4 : radius
                let circle = Path(
                    ellipseIn: CGRect(x: root.x - r, y: root.y - r, width: r * 2, height: r * 2)
                )
                context.fill(
                    circle,
                    with: .color(willDetach ? WhiteboardStyle.pinDetachColor : WhiteboardStyle.pinColor)
                )
                context.stroke(
                    circle,
                    with: .color(willDetach ? .white : WhiteboardStyle.pinBorderColor),
                    lineWidth: 1.5
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hit area for the pins only: small screen-space circles, so clicks anywhere
/// else fall through to the notes and images underneath.
private struct PinHitShape: Shape {
    let points: [CGPoint]
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var combined = Path()
        for point in points {
            combined.addEllipse(
                in: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2
                )
            )
        }
        return combined
    }
}

/// Dragging a pin to a different point on its picture.
///
/// Only present in hand mode: with the string tool up, a click on an image
/// means "pin this point and connect it", which is the tool's whole job, and a
/// pin-drag surface over the image would swallow it.
struct PinInteractionLayer: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        Color.clear
            .contentShape(
                PinHitShape(
                    points: store.visiblePins().compactMap { store.pinRootPoint($0) },
                    radius: WhiteboardStyle.pinGrabRadius
                )
            )
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                    .onChanged { value in
                        if store.pinGesture == nil {
                            guard let pin = store.pin(atRoot: value.startLocation) else { return }
                            store.beginPinGesture(id: pin.id)
                        }
                        store.updatePinGesture(atRoot: value.location)
                    }
                    .onEnded { _ in store.endPinGesture() }
            )
    }
}
