//
//  FieldViews.swift
//  Conspire
//

import AppKit
import QuartzCore
import SwiftUI

enum FieldPalette {
    static func fill(_ index: Int) -> Color {
        let i = max(0, min(index, WhiteboardStyle.fieldFills.count - 1))
        return WhiteboardStyle.fieldFills[i]
    }

    static func edge(_ index: Int) -> Color {
        let i = max(0, min(index, WhiteboardStyle.fieldEdges.count - 1))
        return WhiteboardStyle.fieldEdges[i]
    }
}

// MARK: - Fills

/// The fields themselves, drawn behind everything else on the canvas.
///
/// These are Core Animation shape layers rather than SwiftUI drawing. A field is
/// a large translucent area, and SwiftUI's `Canvas` rasterises on the CPU, so the
/// cost tracked the pixels covered rather than the shape's complexity: six fields
/// at 3x zoom measured 86ms a frame. (Simplifying the outlines made it *worse*,
/// and the blend mode was never the expensive part.)
///
/// As shape layers the GPU does the compositing, a ring is rasterised only when
/// it actually changes, and panning or zooming is a transform on the container
/// layer — no redraw of anything.
struct FieldLayerView: NSViewRepresentable {
    @ObservedObject var store: WhiteboardStore

    func makeNSView(context: Context) -> FieldLayerHostView {
        FieldLayerHostView()
    }

    func updateNSView(_ view: FieldLayerHostView, context: Context) {
        view.apply(fields: store.fields, pan: store.pixelSnappedPan, scale: store.canvasScale)
    }
}

final class FieldLayerHostView: NSView {
    private let container = CALayer()
    private var shapes: [UUID: CAShapeLayer] = [:]
    /// Last ring committed to each layer, so a path is only rebuilt when it moves.
    private var renderedRings: [UUID: FieldRing] = [:]

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

    /// Purely decorative; interaction is handled by `FieldInteractionLayer`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// World space is y-down from the top left; Core Animation is y-up from the
    /// bottom left. The flip is baked into the transform rather than relying on
    /// `isGeometryFlipped`, so the mapping is explicit and testable.
    static func canvasTransform(pan: CGSize, scale: CGFloat, viewHeight: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: pan.width, y: viewHeight - pan.height)
            .scaledBy(x: scale, y: -scale)
    }

    /// The offset that turns `base` into `moved`, or nil if the shape itself changed.
    static func pureTranslation(from base: FieldRing, to moved: FieldRing) -> CGSize? {
        guard base.count == moved.count, let first = base.first, let movedFirst = moved.first
        else { return nil }
        let dx = movedFirst.x - first.x
        let dy = movedFirst.y - first.y
        let tolerance: CGFloat = 0.0001
        for i in base.indices {
            if abs((moved[i].x - base[i].x) - dx) > tolerance { return nil }
            if abs((moved[i].y - base[i].y) - dy) > tolerance { return nil }
        }
        return CGSize(width: dx, height: dy)
    }

    func apply(fields: [Field], pan: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        container.bounds = CGRect(origin: .zero, size: bounds.size)
        container.setAffineTransform(
            Self.canvasTransform(pan: pan, scale: scale, viewHeight: bounds.height)
        )

        // Rasterise the vectors near the zoom they are shown at, but in coarse
        // steps so a pinch does not force a re-rasterise on every frame.
        let density = window?.backingScaleFactor ?? 2
        let quantised = max(0.5, (scale * 2).rounded() / 2)
        let contentsScale = density * min(quantised, 3)

        var live = Set<UUID>()
        for (index, field) in fields.enumerated() {
            live.insert(field.id)
            let shape = shapes[field.id] ?? makeShape(for: field.id)

            // Dragging a field rewrites every point of its ring, which would look
            // like a new shape and rebuild the path on every frame. A bodily move
            // is just a translation, so move the layer instead.
            if let base = renderedRings[field.id] {
                if base != field.ring {
                    if let delta = Self.pureTranslation(from: base, to: field.ring) {
                        shape.setAffineTransform(
                            CGAffineTransform(translationX: delta.width, y: delta.height)
                        )
                    } else {
                        shape.path = FieldGeometry.path(field.ring).cgPath
                        shape.setAffineTransform(.identity)
                        renderedRings[field.id] = field.ring
                    }
                }
            } else {
                shape.path = FieldGeometry.path(field.ring).cgPath
                shape.setAffineTransform(.identity)
                renderedRings[field.id] = field.ring
            }
            shape.fillColor = NSColor(
                FieldPalette.fill(field.colourIndex).opacity(WhiteboardStyle.fieldFillOpacity)
            ).cgColor
            shape.strokeColor = NSColor(
                FieldPalette.edge(field.colourIndex).opacity(WhiteboardStyle.fieldEdgeOpacity)
            ).cgColor
            shape.lineWidth = WhiteboardStyle.fieldEdgeWidth
            if shape.contentsScale != contentsScale { shape.contentsScale = contentsScale }
            if shape.zPosition != CGFloat(index) { shape.zPosition = CGFloat(index) }
        }

        for (id, shape) in shapes where !live.contains(id) {
            shape.removeFromSuperlayer()
            shapes.removeValue(forKey: id)
            renderedRings.removeValue(forKey: id)
        }
    }

    private func makeShape(for id: UUID) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.anchorPoint = .zero
        shape.position = .zero
        shape.masksToBounds = false
        shape.lineJoin = .round
        // Overlapping fields read as a darker intersection.
        shape.compositingFilter = "multiplyBlendMode"
        container.addSublayer(shape)
        shapes[id] = shape
        return shape
    }

    // MARK: - Test visibility

    var shapeLayerCount: Int { shapes.count }
    var shapeLayerIdentity: Set<ObjectIdentifier> { Set(shapes.values.map(ObjectIdentifier.init)) }
    var firstShapePath: CGPath? { shapes.values.first?.path }
    var firstShapeTranslation: CGSize {
        guard let t = shapes.values.first?.affineTransform() else { return .zero }
        return CGSize(width: t.tx, height: t.ty)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
    }
}

// MARK: - Labels

struct FieldLabelsView: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.fields) { field in
                let box = FieldGeometry.bounds(field.ring)
                let centre = FieldGeometry.centroid(field.ring)
                let count = store.memberNoteCount(of: field)

                HStack(spacing: 5) {
                    Text(field.label.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.5)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .opacity(0.65)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    FieldPalette.edge(field.colourIndex)
                        .opacity(store.selectedFieldID == field.id ? 1 : 0.78),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .fixedSize()
                .position(x: centre.x, y: box.minY - 10)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Overlay (draft stroke, hover falloff, handles, selection)

/// Interaction feedback, drawn above the notes. Also a screen-space `Canvas`, so
/// it costs one layer instead of a transformed stack of shapes.
struct FieldOverlayView: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            let scale = max(store.canvasScale, 0.01)
            let pan = store.pixelSnappedPan
            // Line weights are specified in world units, so divide by the scale to
            // keep them constant on screen.
            let hair = 1 / scale

            context.translateBy(x: pan.width, y: pan.height)
            context.scaleBy(x: scale, y: scale)

            drawDraftStroke(in: &context, hair: hair)
            drawHoverArc(in: &context, hair: hair)
            drawSelection(in: &context, hair: hair)
        }
        .allowsHitTesting(false)
    }

    /// The stroke being drawn says what it is about to do: carve, extend, or create.
    private func drawDraftStroke(in context: inout GraphicsContext, hair: CGFloat) {
        guard store.fieldDraftStroke.count > 1 else { return }
        let host = store.field(withID: store.fieldDraftHostID)
        let colour: Color = store.fieldDraftIsCarve
            ? Color(red: 0.75, green: 0.23, blue: 0.17)
            : FieldPalette.edge(host?.colourIndex ?? store.fieldColourPicked)

        let stroke = openPath(store.fieldDraftStroke, closed: true)
        if !store.fieldDraftIsCarve {
            context.fill(stroke, with: .color(colour.opacity(0.12)))
        }
        context.stroke(
            stroke,
            with: .color(colour),
            style: StrokeStyle(
                lineWidth: 2.5 * hair, lineCap: .round, dash: [6 * hair, 5 * hair]
            )
        )

        // While extending, outline the host so it is clear what grows.
        if let host, !store.fieldDraftIsCarve {
            context.stroke(
                FieldGeometry.path(host.ring),
                with: .color(FieldPalette.edge(host.colourIndex).opacity(0.8)),
                style: StrokeStyle(lineWidth: 2 * hair, lineCap: .round)
            )
        }
    }

    /// Hovering an outline highlights exactly the arc a drag would move.
    private func drawHoverArc(in context: inout GraphicsContext, hair: CGFloat) {
        guard let hover = store.fieldHoverEdge,
              hover.points.count > 1,
              let field = store.field(withID: hover.fieldID) else { return }
        context.stroke(
            openPath(hover.points, closed: false),
            with: .color(FieldPalette.edge(field.colourIndex).opacity(0.75)),
            style: StrokeStyle(lineWidth: 5 * hair, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawSelection(in context: inout GraphicsContext, hair: CGFloat) {
        guard let field = store.field(withID: store.selectedFieldID) else { return }
        let colour = FieldPalette.edge(field.colourIndex)
        context.stroke(
            FieldGeometry.path(field.ring),
            with: .color(colour.opacity(0.9)),
            style: StrokeStyle(
                lineWidth: 2 * hair, lineCap: .round, dash: [5 * hair, 4 * hair]
            )
        )

        guard store.fieldReshapeMode == .handles else { return }
        for index in FieldGeometry.handleIndices(field.ring) {
            let point = field.ring[index]
            let box = CGRect(
                x: point.x - 5 * hair, y: point.y - 5 * hair,
                width: 10 * hair, height: 10 * hair
            )
            context.fill(Circle().path(in: box), with: .color(.white))
            context.stroke(
                Circle().path(in: box), with: .color(colour), lineWidth: 2 * hair
            )
        }
    }

    private func openPath(_ points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }
}

// MARK: - Pencil surface

/// Present only while the pencil is out. It sits above the notes so a stroke can
/// be drawn straight across them.
struct FieldDrawingLayer: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                    .onChanged { value in
                        store.updateFieldStroke(
                            startRoot: value.startLocation,
                            currentRoot: value.location
                        )
                    }
                    .onEnded { _ in
                        store.endFieldStroke()
                    }
            )
    }
}

// MARK: - Reshape surface

/// Hit area for reshaping and moving fields: the field interiors plus a grab
/// band along each outline, in root coordinates. Everything else falls through
/// to the canvas below, so clicking empty space still creates a note.
private struct FieldHitShape: Shape {
    let fields: [Field]
    let scale: CGFloat
    let pan: CGSize
    let grab: CGFloat

    func path(in rect: CGRect) -> Path {
        var combined = Path()
        for field in fields {
            let rootRing = field.ring.map {
                CGPoint(x: $0.x * scale + pan.width, y: $0.y * scale + pan.height)
            }
            guard rootRing.count > 2 else { continue }
            let outline = FieldGeometry.path(rootRing)
            combined.addPath(outline)
            combined.addPath(
                outline.strokedPath(
                    StrokeStyle(lineWidth: grab * 2, lineCap: .round, lineJoin: .round)
                )
            )
        }
        return combined
    }
}

/// Sits below the notes, so a click on a note still belongs to the note.
struct FieldInteractionLayer: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        Color.clear
            .contentShape(
                FieldHitShape(
                    fields: store.fields,
                    scale: store.canvasScale,
                    pan: store.pixelSnappedPan,
                    grab: FieldGeometry.edgeGrab
                )
            )
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                    .onChanged { value in
                        if store.fieldGesture == nil {
                            store.beginFieldGesture(atRoot: value.startLocation)
                        }
                        store.updateFieldGesture(atRoot: value.location)
                    }
                    .onEnded { value in
                        if store.fieldGesture == nil {
                            store.beginFieldGesture(atRoot: value.startLocation)
                        }
                        store.endFieldGesture()
                    }
            )
    }
}

// MARK: - Inline inspector

/// Rename, recolour or delete the selected field, mirroring the string inspector.
struct FieldInlineInspector: View {
    @ObservedObject var store: WhiteboardStore
    let field: Field
    @State private var labelDraft: String = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Label", text: Binding(
                get: { labelDraft },
                set: { labelDraft = $0; store.setSelectedFieldLabel($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)

            ForEach(0..<WhiteboardStyle.fieldFills.count, id: \.self) { index in
                Button {
                    store.pickFieldColour(index)
                } label: {
                    Circle()
                        .fill(FieldPalette.fill(index))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().stroke(
                                Color.primary.opacity(field.colourIndex == index ? 0.8 : 0),
                                lineWidth: 2
                            )
                        )
                }
                .buttonStyle(.plain)
            }

            Button(role: .destructive) {
                store.deleteSelectedField()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .modifier(PanelBackground(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { labelDraft = field.label }
        .onChange(of: field.id) { _, _ in labelDraft = field.label }
    }
}
