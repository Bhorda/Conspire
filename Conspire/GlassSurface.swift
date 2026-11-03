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
    /// Escape hatch, if glass ever costs more than it is worth.
    @AppStorage("useGlassPanels") private var useGlassPanels: Bool = true
    /// macOS dims chrome in windows that are not frontmost.
    @Environment(\.appearsActive) private var appearsActive
    /// Whether the canvas is moving under this panel right now.
    @Environment(\.canvasIsMoving) private var canvasIsMoving

    var cornerRadius: CGFloat = WhiteboardStyle.panelCornerRadius

    func body(content: Content) -> some View {
        content
            .containerShape(.rect(cornerRadius: cornerRadius))
            .modifier(
                PanelSurface(
                    cornerRadius: cornerRadius,
                    // Blur is the one thing here that cannot be cached while
                    // the backdrop changes, so it stands down for the gesture.
                    glass: useGlassPanels && !canvasIsMoving
                )
            )
            .opacity(appearsActive ? 1 : WhiteboardStyle.inactiveChromeOpacity)
    }
}

private struct CanvasIsMovingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set once at the root from `WhiteboardStore.isCanvasMoving`, so every
    /// panel can stand its blur down without each one observing the store.
    var canvasIsMoving: Bool {
        get { self[CanvasIsMovingKey.self] }
        set { self[CanvasIsMovingKey.self] = newValue }
    }
}

private struct PanelSurface: ViewModifier {
    let cornerRadius: CGFloat
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                .transition(.opacity)
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

// MARK: - Role: an inline inspector

/// The small panel that hangs off a selected object — a field, a string, a note.
///
/// A capsule rather than a rounded rectangle, so it belongs to the same family
/// as the chrome chips instead of introducing a third corner radius.
struct GlassCapsule: ViewModifier {
    @AppStorage("useGlassPanels") private var useGlassPanels: Bool = true
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.canvasIsMoving) private var canvasIsMoving

    func body(content: Content) -> some View {
        content
            .containerShape(.capsule)
            .modifier(CapsuleSurface(glass: useGlassPanels && !canvasIsMoving))
            .opacity(appearsActive ? 1 : WhiteboardStyle.inactiveChromeOpacity)
    }
}

private struct CapsuleSurface: ViewModifier {
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
            )
        }
    }
}

extension View {
    /// An inspector hanging off a selected object.
    func glassCapsule() -> some View {
        modifier(GlassCapsule())
    }

    /// A text field inside an inspector: a capsule, echoing the one around it.
    /// `.roundedBorder` was the third corner radius in the app.
    func capsuleField(width: CGFloat) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: width)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
    }

    /// A colour dot in an inspector, ringed when it is the current choice.
    func colourDot(isSelected: Bool) -> some View {
        frame(width: 17, height: 17)
            .overlay(
                Circle().stroke(
                    Color.primary.opacity(isSelected ? 0.85 : 0),
                    lineWidth: 2
                )
            )
            .contentShape(.circle)
    }
}
