//
//  ModifierFlagsMonitor.swift
//  Conspire
//
//  Created by Benjamin Searle on 04/05/2026.
//

import AppKit
import SwiftUI

/// Hidden view that updates bindings whenever modifier keys change (local to this app’s windows).
struct ModifierFlagsMonitor: NSViewRepresentable {
    @Binding var shift: Bool
    @Binding var command: Bool
    @Binding var option: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shift: $shift, command: $command, option: $option)
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.install()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shift = $shift
        context.coordinator.command = $command
        context.coordinator.option = $option
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var shift: Binding<Bool>
        var command: Binding<Bool>
        var option: Binding<Bool>
        private var monitor: Any?

        init(shift: Binding<Bool>, command: Binding<Bool>, option: Binding<Bool>) {
            self.shift = shift
            self.command = command
            self.option = option
        }

        func install() {
            guard monitor == nil else { return }
            syncFromFlags(NSEvent.modifierFlags)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] _ in
                guard let self else { return nil }
                self.syncFromFlags(NSEvent.modifierFlags)
                return nil
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func syncFromFlags(_ f: NSEvent.ModifierFlags) {
            Task { @MainActor in
                shift.wrappedValue = f.contains(.shift)
                command.wrappedValue = f.contains(.command)
                option.wrappedValue = f.contains(.option)
            }
        }
    }
}

/// Compact row: grey when up, white while held.
struct ModifierKeyTooltip: View {
    @Binding var shift: Bool
    @Binding var command: Bool
    @Binding var option: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shift.fill")
                .foregroundStyle(shift ? Color.white : Color.gray.opacity(0.4))
            Image(systemName: "option")
                .foregroundStyle(option ? Color.white : Color.gray.opacity(0.4))
            Image(systemName: "command")
                .foregroundStyle(command ? Color.white : Color.gray.opacity(0.4))
        }
    }
}
