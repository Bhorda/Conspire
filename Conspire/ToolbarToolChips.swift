//
//  ToolbarToolChips.swift
//  Conspire
//

import SwiftUI

/// The tool chips along the bottom toolbar.
///
/// Fill is the only indicator. Exactly one symbol in the whole row is filled —
/// the tool that is up, drawn in the colour it will use — and everything else
/// is an outline at full strength. So an inactive tool shows no filled swatch
/// at all, even though it remembers which colour it would use; that belongs to
/// the moment you pick it up, not to the resting row.
///
/// Nothing here animates. These symbols change state in bursts (every creation
/// hands the tool back on its own), and a transition on each one reads as
/// flicker rather than feedback.

/// Outline and filled forms of one tool's symbol. Several of these are not
/// `.fill` variants of each other (`circle.dashed.fill` does not exist), so
/// the pair is named explicitly rather than derived with `.symbolVariant`.
struct ToolSymbolPair {
    let outline: String
    let filled: String

    static let hand = ToolSymbolPair(outline: "hand.raised", filled: "hand.raised.fill")
    /// The hand with something in it. Picking notes up is the one thing the
    /// hand does that has no other sign in the chrome — the pile follows the
    /// pointer, so if you look away from it there is nothing to say you are
    /// still holding anything.
    static let handCarrying = ToolSymbolPair(
        outline: "rectangle.and.hand.point.up.left",
        filled: "rectangle.and.hand.point.up.left.fill"
    )
    static let note = ToolSymbolPair(outline: "square", filled: "square.inset.filled")
    static let string = ToolSymbolPair(
        outline: "point.bottomleft.forward.to.point.topright.scurvepath",
        filled: "point.bottomleft.forward.to.point.topright.scurvepath.fill"
    )
    static let field = ToolSymbolPair(outline: "circle.dashed", filled: "circle.dashed.inset.filled")

    func name(filled: Bool) -> String { filled ? self.filled : outline }
}

/// Shared chip metrics, so the hand and the swatch rows are the same pill.
private struct ToolChipContainer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(height: WhiteboardStyle.toolbarChipHeight)
            // A glass button otherwise only answers on its symbol, so the
            // whole pill has to be claimed as the hit area.
            .contentShape(.capsule)
            .chromeChip(in: .capsule)
    }
}

/// The hand: the resting state, so it leads the row and carries no colour.
struct HandToolChip: View {
    let isActive: Bool
    let isCarrying: Bool
    let activate: () -> Void

    private var symbols: ToolSymbolPair {
        isCarrying ? .handCarrying : .hand
    }

    var body: some View {
        Button(action: activate) {
            Image(systemName: symbols.name(filled: isActive))
                .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .frame(height: WhiteboardStyle.toolbarChipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)
        .chromeChip(in: .capsule)
        .help(
            isCarrying
                ? "Holding notes — click to put them down, Esc to drop them here"
                : "Hand — move and adjust anything, create nothing (Esc)"
        )
    }
}

/// One tool's colour swatches in a single chip.
struct ToolSwatchRow: View {
    let symbols: ToolSymbolPair
    let colours: [Color]
    let picked: Int
    let isActive: Bool
    let help: String
    let pick: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(colours.indices, id: \.self) { index in
                Button {
                    pick(index)
                } label: {
                    Image(systemName: symbols.name(filled: isActive && picked == index))
                        .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                        .foregroundStyle(colours[index])
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(ToolChipContainer())
        .help(help)
    }
}
