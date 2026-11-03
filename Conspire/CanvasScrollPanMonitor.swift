//
//  CanvasScrollPanMonitor.swift
//  Conspire
//
//  Bridges macOS trackpad/mouse scroll-wheel deltas into canvas pan updates.
//

import AppKit
import SwiftUI

/// Fills the canvas and listens for local `scrollWheel` events in root-space.
final class CanvasScrollPanHostView: NSView {
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, let store = self.store else { return event }
            guard let win = self.window, event.window === win else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.width > 1, self.bounds.height > 1, self.bounds.contains(local) else {
                return event
            }

            // Natural-feeling canvas pan: two-finger scroll moves the canvas in scroll direction.
            let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            MainActor.assumeIsolated {
                store.applyPan(delta)
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    func attachIfNeeded() {
        installMonitor()
    }
}

struct CanvasScrollPanMonitor: NSViewRepresentable {
    @ObservedObject var store: WhiteboardStore

    func makeNSView(context: Context) -> CanvasScrollPanHostView {
        let view = CanvasScrollPanHostView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: CanvasScrollPanHostView, context: Context) {
        nsView.store = store
        nsView.attachIfNeeded()
    }
}
