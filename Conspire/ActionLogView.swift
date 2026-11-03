//
//  ActionLogView.swift
//  Conspire
//

import SwiftUI

struct ActionLogView: View {
    @ObservedObject var store: WhiteboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(store.actionLog.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .padding(8)
        .frame(maxWidth: 280, alignment: .leading)
    }
}
