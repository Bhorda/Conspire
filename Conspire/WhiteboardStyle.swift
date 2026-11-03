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
    /// In root space: bottom-center of the carried pile is placed this far down-right of the pointer so the card does not sit under the cursor and block hit-testing.
    static let handFollowOffset = CGSize(
        width: noteSize.width / 2 + 36,
        height: noteSize.height / 2 + 36
    )
    static let editButtonSize: CGFloat = 22
    /// Bottom glass toolbar: shared chip height, symbol size, and inter-chip spacing.
    static let toolbarChipHeight: CGFloat = 44
    static let toolbarSymbolSize: CGFloat = 17
    static let toolbarSpacing: CGFloat = 8
    static let textPadding: CGFloat = 8
    static let displayMaxLines = 6
}

