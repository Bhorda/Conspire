//
//  FieldControlPanel.swift
//  Conspire
//

import SwiftUI

/// Top-right panel for the field shaping parameters.
///
/// Brush is live — it changes the falloff of the next edge drag, and the hover
/// highlight shows it. Join and Tidy are read at the moment a stroke lands, so
/// moving them does not restyle fields already on the board.
struct FieldControlPanel: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: WhiteboardStyle.toolbarSymbolSize - 3, weight: .semibold))
                Text("Field")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                reshapeToggle
            }

            slider(
                title: "Brush",
                help: "How much of the outline follows when you drag an edge",
                value: $store.fieldBrushRadius,
                range: WhiteboardStyle.fieldBrushRange,
                readout: "\(Int(store.fieldBrushRadius))"
            )

            slider(
                title: "Join",
                help: "Fillet radius where a new stroke merges into a field",
                value: $store.fieldJoinSoftness,
                range: WhiteboardStyle.fieldJoinRange,
                readout: "\(Int(store.fieldJoinSoftness))"
            )

            slider(
                title: "Tidy",
                help: "How much a freshly drawn stroke is smoothed",
                value: Binding(
                    get: { Double(store.fieldTidyPasses) },
                    set: { store.fieldTidyPasses = Int($0.rounded()) }
                ),
                range: WhiteboardStyle.fieldTidyRange,
                step: 1,
                readout: "\(store.fieldTidyPasses)"
            )
            }
        .padding(WhiteboardStyle.panelPadding + 2)
        .frame(width: 232)
        .glassPanel()
    }

    private var reshapeToggle: some View {
        HStack(spacing: 2) {
            ForEach(FieldReshapeMode.allCases, id: \.self) { mode in
                Button {
                    store.fieldReshapeMode = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            ConcentricRectangle(
                                uniformTopCorners: .concentric(minimum: .fixed(6)),
                                uniformBottomCorners: .concentric(minimum: .fixed(6))
                            )
                            .fill(Color.primary.opacity(store.fieldReshapeMode == mode ? 0.16 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    mode == .clay
                        ? "Push and pull the outline with a soft falloff"
                        : "Drag individual control handles"
                )
            }
        }
    }

    @ViewBuilder
    private func slider<V: BinaryFloatingPoint>(
        title: String,
        help: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        step: V.Stride? = nil,
        readout: String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(readout)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
        .help(help)
    }
}
