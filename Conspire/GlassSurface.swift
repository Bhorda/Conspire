//
//  GlassSurface.swift
//  Conspire
//

import SwiftUI

/// Every surface in the app, as a small set of roles.
///
/// One rule decides which role something gets: **glass is the floating control
/// layer. Nothing inside glass is glass, and nothing on the canvas is glass.**
/// Glass cannot sample other glass, so a glass control inside a glass panel is
/// both wrong to look at and an extra offscreen pass to draw. And the canvas is
/// content — the thing glass is supposed to be floating *above*.
///
/// So: chrome and panels are glass; their contents are insets; markers on the
/// board are neither.

// MARK: - Role: a floating panel

/// Boards, the library, the field controls.
///
/// Carries the container shape as well as the surface, so anything inside can
/// use `ConcentricRectangle` and get a corner radius that actually relates to
/// this one instead of a hard-coded guess.
struct GlassPanel: ViewModifier {
    /// Escape hatch. A glass panel re-blurs every frame while the canvas moves
    /// underneath it, which was once the app's last real stutter. Fields and
    /// images have since moved to Core Animation, so the budget is far larger —
    /// but the blur is not free, and this is the switch if it shows.
    @AppStorage("useGlassPanels") private var useGlassPanels: Bool = true
    /// macOS dims chrome in windows that are not frontmost.
    @Environment(\.appearsActive) private var appearsActive

    var cornerRadius: CGFloat = WhiteboardStyle.panelCornerRadius

    func body(content: Content) -> some View {
        content
            .containerShape(.rect(cornerRadius: cornerRadius))
            .modifier(PanelSurface(cornerRadius: cornerRadius, glass: useGlassPanels))
            .opacity(appearsActive ? 1 : WhiteboardStyle.inactiveChromeOpacity)
    }
}

private struct PanelSurface: ViewModifier {
    let cornerRadius: CGFloat
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.primary.opacity(0.14))
                    )
            )
        }
    }
}

// MARK: - Role: a control inside a panel

/// Search fields, library rows, anything sitting *on* a panel.
///
/// Never glass. The radius is derived from the panel's container shape, so
/// insets stay concentric with the surface they are on however that changes.
struct InsetControl: ViewModifier {
    var minimumRadius: CGFloat = WhiteboardStyle.insetCornerRadiusMinimum
    var fill: Double = 0.07

    func body(content: Content) -> some View {
        content.background(
            // Radii come from the enclosing panel's `containerShape`, so an
            // inset stays concentric with the surface it sits on however that
            // changes. The minimum keeps small insets from going square.
            ConcentricRectangle(
                uniformTopCorners: .concentric(minimum: .fixed(minimumRadius)),
                uniformBottomCorners: .concentric(minimum: .fixed(minimumRadius))
            )
            .fill(Color.primary.opacity(fill))
        )
    }
}

// MARK: - Convenience

extension View {
    /// A floating panel: glass, concentric, and dimmed when the window is not
    /// frontmost.
    func glassPanel(cornerRadius: CGFloat = WhiteboardStyle.panelCornerRadius) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }

    /// A control sitting on a panel.
    func insetControl(
        minimumRadius: CGFloat = WhiteboardStyle.insetCornerRadiusMinimum,
        fill: Double = 0.07
    ) -> some View {
        modifier(InsetControl(minimumRadius: minimumRadius, fill: fill))
    }

    /// A chip in the floating chrome — a toolbar group, a round button.
    ///
    /// `.interactive()` is what makes glass respond to a click on macOS, so it
    /// belongs on everything clickable and nowhere else.
    func chromeChip<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular.interactive(), in: shape)
    }

    /// A chip that only displays — no click, so no interactive response.
    func chromeReadout<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}
