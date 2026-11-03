//
//  CanvasPinchZoomMonitor.swift
//  Conspire
//
//  Bridges trackpad pinch magnification into canvas zoom updates.
//

import AppKit
import SwiftUI

final class CanvasPinchZoomHostView: NSView {
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
            guard let self, let store = self.store else { return event }
            guard let win = self.window, event.window === win else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.width > 1, self.bounds.height > 1, self.bounds.contains(local) else {
                return event
            }
            let rootPoint = CGPoint(x: local.x, y: local.y)
            MainActor.assumeIsolated {
                store.applyZoom(magnification: event.magnification, atRootPoint: rootPoint)
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

struct CanvasPinchZoomMonitor: NSViewRepresentable {
    @ObservedObject var store: WhiteboardStore

    func makeNSView(context: Context) -> CanvasPinchZoomHostView {
        let view = CanvasPinchZoomHostView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: CanvasPinchZoomHostView, context: Context) {
        nsView.store = store
        nsView.attachIfNeeded()
    }
}
