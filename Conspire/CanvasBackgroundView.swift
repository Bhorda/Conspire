//
//  CanvasBackgroundView.swift
//  Conspire
//

import SwiftUI
import AppKit


/// Empty canvas: a click creates or places a note. Panning is scroll-driven
/// (`CanvasScrollPanMonitor`), so no drag gesture competes with notes or toolbar controls.
struct CanvasBackgroundView: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        ZStack {
            WhiteboardStyle.canvasBackground
            DotGridView(pan: store.pixelSnappedPan, scale: store.canvasScale)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            store.handleBackgroundPrimaryTap(atRootPoint: location)
        }
    }
}

/// Builds the dot lattice once per viewport size and spacing.
///
/// The dots are a regular grid, so panning is a translation of the same path —
/// there is no reason to rebuild thousands of ellipses on every frame.
final class DotGridPathCache {
    private var spacing: CGFloat = -1
    private var size: CGSize = .zero
    private var radius: CGFloat = -1
    private var cached = Path()

    func lattice(spacing: CGFloat, size: CGSize, radius: CGFloat) -> Path {
        if spacing == self.spacing, size == self.size, radius == self.radius {
            return cached
        }
        var path = Path()
        // One row/column of slack on each side covers the pan translation.
        var y = -spacing
        while y <= size.height + spacing {
            var x = -spacing
            while x <= size.width + spacing {
                path.addEllipse(
                    in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                )
                x += spacing
            }
            y += spacing
        }
        self.spacing = spacing
        self.size = size
        self.radius = radius
        self.cached = path
        return path
    }

    /// Screen gap between dots, doubling when zoomed far out so the lattice keeps
    /// an even density instead of collapsing into a texture.
    static func screenSpacing(scale: CGFloat) -> CGFloat {
        var spacing = WhiteboardStyle.dotGridSpacing * scale
        guard spacing > 0.5 else { return 0 }
        while spacing < WhiteboardStyle.dotGridMinScreenSpacing {
            spacing *= 2
        }
        return spacing
    }
}

/// Dots anchored to the world origin, so the grid travels with the board rather
/// than with the window.
private struct DotGridView: View {
    let pan: CGSize
    let scale: CGFloat

    @State private var cache = DotGridPathCache()

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let spacing = DotGridPathCache.screenSpacing(scale: scale)
            guard spacing > 0, size.width > 0, size.height > 0 else { return }

            let lattice = cache.lattice(
                spacing: spacing, size: size, radius: WhiteboardStyle.dotGridRadius
            )
            context.translateBy(
                x: pan.width.truncatingRemainder(dividingBy: spacing),
                y: pan.height.truncatingRemainder(dividingBy: spacing)
            )
            context.fill(lattice, with: .color(WhiteboardStyle.dotGridColor))
        }
    }
}
