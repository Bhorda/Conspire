//
//  ToolbarToolChips.swift
//  Conspire
//

import SwiftUI

/// The tool chips along the bottom toolbar.
///
/// Two separate things have to read at a glance, and conflating them was the
/// problem with the indicator dots: *which tool is up* belongs to the whole
/// container, which is accented while that tool is active, and *which colour
/// it will use* belongs to one symbol inside it, which switches to its filled
/// variant. Colours stay at full strength in both states — dimming the
/// unpicked ones made them look unavailable rather than merely not chosen.

/// Outline and filled forms of one tool's symbol. Several of these are not
/// `.fill` variants of each other (`circle.dashed.fill` does not exist), so
/// the pair is named explicitly rather than derived with `.symbolVariant`.
struct ToolSymbolPair {
    let outline: String
    let filled: String

    static let hand = ToolSymbolPair(outline: "hand.raised", filled: "hand.raised.fill")
    static let note = ToolSymbolPair(outline: "square", filled: "square.inset.filled")
    static let string = ToolSymbolPair(
        outline: "point.bottomleft.forward.to.point.topright.scurvepath",
        filled: "point.bottomleft.forward.to.point.topright.scurvepath.fill"
    )
    static let field = ToolSymbolPair(outline: "circle.dashed", filled: "circle.dashed.inset.filled")
}

/// Glass pill sized like every other chip, tinted while its tool is up.
private struct ToolChipContainer: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(height: WhiteboardStyle.toolbarChipHeight)
            .glassEffect(isActive ? Glass.regular.tint(.accentColor) : Glass.regular)
    }
}

/// The hand: the resting state, so it leads the row and carries no colour.
/// Deliberately not animated between its two forms — this one flips often
/// enough, and on its own after every creation, that a transition reads as
/// flicker rather than feedback.
struct HandToolChip: View {
    let isActive: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            Image(systemName: isActive ? ToolSymbolPair.hand.filled : ToolSymbolPair.hand.outline)
                .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: WhiteboardStyle.toolbarChipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(isActive ? Glass.regular.tint(.accentColor) : Glass.regular)
        .help("Hand — move and adjust anything, create nothing (Esc)")
    }
}

/// One tool's colour swatches in a single container.
struct ToolSwatchRow: View {
    let symbols: ToolSymbolPair
    let colours: [Color]
    let picked: Int
    let isActive: Bool
    let help: String
    let unionID: String
    let namespace: Namespace.ID
    let pick: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(colours.indices, id: \.self) { index in
                Button {
                    pick(index)
                } label: {
                    Image(systemName: picked == index ? symbols.filled : symbols.outline)
                        .font(.system(size: WhiteboardStyle.toolbarSymbolSize, weight: .semibold))
                        .contentTransition(.symbolEffect)
                        .foregroundStyle(colours[index])
                }
                .buttonStyle(.plain)
                .glassEffectUnion(id: unionID, namespace: namespace)
            }
        }
        .modifier(ToolChipContainer(isActive: isActive))
        .help(help)
    }
}
