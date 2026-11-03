//
//  CanvasRightClickMonitor.swift
//  Conspire
//
//  One local `rightMouseDown` monitor scoped to the whiteboard’s root rect (same coordinates as hover).
//

import AppKit
import SwiftUI

/// Fills the canvas; installs a single `rightMouseDown` monitor and maps to root coordinates.
final class CanvasRightClickHostView: NSView {
    weak var store: WhiteboardStore?

    private var monitor: Any?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        installMonitor()
    }

    override func removeFromSuperview() {
        removeMonitor()
        super.removeFromSuperview()
    }

    private func installMonitor() {
        guard monitor == nil, window != nil, store != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let store = self.store else { return event }
            guard let win = self.window, event.window === win else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.width > 1, self.bounds.height > 1, self.bounds.contains(local) else {
                return event
            }
            let rootPoint = CGPoint(x: local.x, y: local.y)
            let modifiers = InputModifiers(
                shift: event.modifierFlags.contains(.shift),
                command: event.modifierFlags.contains(.command),
                option: event.modifierFlags.contains(.option)
            )
            Task { @MainActor in
                store.handleRightMouseDown(atRootPoint: rootPoint, modifiers: modifiers)
            }
            return event
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// SwiftUI can set `window` after the first layout pass; retry once `bounds` are valid.
    func attachIfNeeded() {
        installMonitor()
    }
}

struct CanvasRightClickMonitor: NSViewRepresentable {
    @ObservedObject var store: WhiteboardStore

    func makeNSView(context: Context) -> CanvasRightClickHostView {
        let view = CanvasRightClickHostView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: CanvasRightClickHostView, context: Context) {
        nsView.store = store
        nsView.attachIfNeeded()
    }
}
