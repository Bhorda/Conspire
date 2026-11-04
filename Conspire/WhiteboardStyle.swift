//
//  WhiteboardStyle.swift
//  Conspire
//

import SwiftUI

enum WhiteboardStyle {
    /// Settle motion shared by notes and the strings attached to them.
    static let notePlacementAnimation: Animation = .easeOut(duration: 0.2)
    static let noteSize = CGSize(width: 180, height: 140)
    static let cornerRadius: CGFloat = 6
    /// Visual offset per card in a stack (bottom → top).
    static let stackDepthOffset = CGSize(width: 5, height: -5)
    static let hoverOutlineColor = Color.orange
    /// Add different outline colours
    static let hoverOutlineColors = [
        Color(red: 0.8, green: 0.78, blue: 0.55),
        Color(red: 0.55, green: 0.8, blue: 0.78),
        Color(red: 0.78, green: 0.55, blue: 0.8)
    ]
    static let hoverOutlineWidth: CGFloat = 2
    /// Focused (editing) note: same hue as the hover outline, deepened and thickened.
    static let focusOutlineWidth: CGFloat = 3
    static let focusOutlineDarkening: Double = 0.35
    static let noteBackground = Color(red: 1, green: 0.98, blue: 0.75)
    /// Add different note colours
    static let noteBackgrounds = [
        Color(red: 1, green: 0.98, blue: 0.75),
        Color(red: 0.75, green: 1, blue: 0.98),
        Color(red: 0.98, green: 0.75, blue: 1)
    ]
    /// String (link) colors
    static let stringColors = [
        Color(red: 0.95, green: 0.45, blue: 0.45), // red-ish
        Color(red: 0.45, green: 0.7, blue: 0.95),  // blue-ish
        Color(red: 0.55, green: 0.85, blue: 0.55)  // green-ish
    ]

    // MARK: - Fields (zones)

    /// Field fills. Drawn with `.multiply` so overlapping fields read as a
    /// darker intersection rather than one simply covering the other.
    static let fieldFills = [
        Color(red: 0.97, green: 0.81, blue: 0.45),
        Color(red: 0.53, green: 0.81, blue: 0.78),
        Color(red: 0.78, green: 0.64, blue: 0.90)
    ]
    /// Outline / label / chip colour per field colour.
    static let fieldEdges = [
        Color(red: 0.73, green: 0.53, blue: 0.11),
        Color(red: 0.14, green: 0.50, blue: 0.47),
        Color(red: 0.47, green: 0.28, blue: 0.66)
    ]
    static let fieldFillOpacity: Double = 0.55
    static let fieldEdgeOpacity: Double = 0.45
    static let fieldEdgeWidth: CGFloat = 2
    /// Falloff radius for clay reshaping, in world px.
    static let fieldBrushRange: ClosedRange<CGFloat> = 40...420
    static let fieldBrushDefault: CGFloat = 150
    /// Fillet radius where two outlines merge.
    static let fieldJoinRange: ClosedRange<CGFloat> = 0...44
    static let fieldJoinDefault: CGFloat = 18
    /// Smoothing passes applied to a freshly drawn stroke.
    static let fieldTidyRange: ClosedRange<Double> = 0...6
    static let fieldTidyDefault: Int = 3
    
    static let canvasBackground = Color.black.opacity(0.01)

    // MARK: - Dot grid

    /// World-space gap between dots, so the grid pans and zooms with the board.
    static let dotGridSpacing: CGFloat = 28
    /// Screen-space dot radius — constant, so dots stay crisp at any zoom.
    static let dotGridRadius: CGFloat = 1
    /// Below this on-screen gap the spacing doubles, keeping density (and the
    /// dot count) steady when zoomed far out.
    static let dotGridMinScreenSpacing: CGFloat = 14
    static let dotGridColor = Color.primary.opacity(0.11)
    /// In **world** space: the bottom-centre of the carried pile sits this far
    /// down-right of the pointer, so the cards never cover the point you are
    /// aiming at. World rather than root, so the gap scales with the cards it
    /// is holding clear of — a fixed screen offset vanished under them as soon
    /// as you zoomed in.
    static let handFollowOffset = CGSize(
        width: noteSize.width / 2 + 36,
        height: noteSize.height / 2 + 36
    )
    static let editButtonSize: CGFloat = 22
    /// Bottom glass toolbar: shared chip height, symbol size, and inter-chip spacing.
    // MARK: - Images

    /// Long edge an imported image is placed at — two notes wide.
    static let imageImportLongEdge: CGFloat = noteSize.width * 2
    /// Floor for the resize handle, so an image cannot be shrunk to nothing.
    static let imageMinimumLongEdge: CGFloat = 60
    static let imageSelectionColor = Color.accentColor
    static let imageSelectionWidth: CGFloat = 2
    /// Screen-space size of the corner resize handle.
    static let imageResizeHandleSize: CGFloat = 14

    // MARK: - Pins

    /// Pins are drawn in screen space at a constant size, so they stay grabbable
    /// at any zoom.
    static let pinRadius: CGFloat = 4.5
    static let pinGrabRadius: CGFloat = 11
    /// How far past the edge of a picture a pin has to be dragged before
    /// letting go detaches it. A screen measurement, so the forgiveness feels
    /// the same at any zoom — the edge itself is never a hair trigger.
    static let pinDetachMargin: CGFloat = 18
    static let pinColor = Color.white
    static let pinDetachColor = Color(red: 0.95, green: 0.3, blue: 0.3)
    static let pinBorderColor = Color.black.opacity(0.55)

    // MARK: - Surfaces
    //
    // One place for the radii, so inner shapes can be concentric with the
    // surfaces they sit on instead of guessing at a number.

    /// Floating panels: boards, the library, the field controls.
    static let panelCornerRadius: CGFloat = 20
    /// Inline inspectors, which are smaller and attached to an object.
    static let inspectorCornerRadius: CGFloat = 14
    /// Floor for a concentric inset, for when a panel's own radius is small.
    static let insetCornerRadiusMinimum: CGFloat = 6
    static let panelPadding: CGFloat = 12
    /// How close glass surfaces have to be before they blend into one shape.
    static let glassContainerSpacing: CGFloat = 10
    /// Distance from the window edge for every floating element, so nothing
    /// sits at a different inset from its neighbours.
    static let chromeInset: CGFloat = 20
    /// Top inset. Larger than the rest because the window has no title bar, so
    /// anything at the top would otherwise sit under the traffic lights.
    static let chromeTopInset: CGFloat = 52
    /// The one gap between chrome elements and between groups of them.
    static let chromeSpacing: CGFloat = 10
    /// Library previews: full panel width, this tall, cropped to fill.
    static let libraryPreviewHeight: CGFloat = 54
    /// macOS dims chrome in a window that is not frontmost.
    static let inactiveChromeOpacity: Double = 0.55
    /// How a floating panel arrives and leaves. Glass reads badly when it
    /// simply appears — it wants to grow out of where it came from.
    static let panelAnimation: Animation = .smooth(duration: 0.24)

    static let toolbarChipHeight: CGFloat = 44
    static let toolbarSymbolSize: CGFloat = 17
    static let toolbarSpacing: CGFloat = 8
    static let textPadding: CGFloat = 8
    static let displayMaxLines = 6
}

