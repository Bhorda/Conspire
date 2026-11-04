//
//  CanvasKeyboardCycleMonitor.swift
//  Conspire
//
//  Bridges stack-related key shortcuts into store handlers.
//

import AppKit
import SwiftUI

/// Virtual key codes. AppKit has no named equivalents for these: `NSEvent.SpecialKey`
/// covers arrows/function keys and omits Escape, and SwiftUI's `KeyEquivalent.escape`
/// only applies to `.keyboardShortcut`, not to an `NSEvent` monitor.
private enum KeyCode {
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
}

/// Fills the canvas and listens for local keyDown events scoped to the whiteboard window.
final class CanvasKeyboardCycleHostView: NSView {
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let store = self.store else { return event }
            guard let win = self.window, event.window === win else { return event }

            let isEditingText = MainActor.assumeIsolated {
                store.editingNoteID != nil || store.isBoardListRenaming
            }

            if event.keyCode == KeyCode.delete {
                // Let Backspace reach focused TextFields (note body or sidebar board rename).
                if isEditingText { return event }
                Task { @MainActor in
                    // A selected image or field is a more specific target than
                    // the hand; only one of them can be selected at a time.
                    if store.carriedGroup != nil {
                        store.handleDeleteHandShortcut()
                    } else if store.selectedImageID != nil {
                        store.deleteSelectedImage()
                    } else if store.selectedFieldID != nil {
                        store.deleteSelectedField()
                    } else if store.selectedLinkID != nil {
                        // A selected string was the one thing Backspace
                        // ignored: it could only be deleted from its inspector.
                        store.deleteSelectedLink()
                    } else if let noteID = store.selectedNoteID {
                        store.selectNote(nil)
                        store.deleteNote(noteID)
                    } else {
                        store.handleDeleteHandShortcut()
                    }
                }
                return nil
            }

            // Escape walks back out of whatever you are in the middle of, one
            // press at a time, and finally puts the tool down. The store owns
            // that order; this only forwards the key and reports whether it was
            // used, so an unused Escape still reaches the responder chain.
            if event.keyCode == KeyCode.escape {
                let handled = MainActor.assumeIsolated { store.handleEscape() }
                return handled ? nil : event
            }

            // ⌘V pastes an image at the cursor.
            if event.charactersIgnoringModifiers == "v",
               event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.option),
               !isEditingText {
                Task { @MainActor in
                    store.importImageFromPasteboard(
                        atWorld: store.rootToWorld(store.cursorInRoot)
                    )
                }
                return nil
            }

            // 1/2/3 pick a note colour; ⌘1/2/3 a string colour; ⌥1/2/3 a field colour.
            if let index = colourShortcutIndex(event), !isEditingText {
                let wantsString = event.modifierFlags.contains(.command)
                let wantsField = event.modifierFlags.contains(.option)
                Task { @MainActor in
                    if wantsField {
                        store.pickFieldColour(index)
                    } else if wantsString {
                        store.pickStringColour(index)
                    } else {
                        store.pickNoteColour(index)
                    }
                }
                return nil
            }

            let isTab = (event.keyCode == KeyCode.tab) || (event.charactersIgnoringModifiers == "\t")
            guard isTab else { return event }

            let isShift = event.modifierFlags.contains(.shift)
            Task { @MainActor in
                if isShift {
                    store.handleCycleBackward()
                } else {
                    store.handleCycleForward()
                }
            }
            return nil
        }
    }

    /// 0-based colour slot for a "1"/"2"/"3" keypress, ignoring modifiers.
    private func colourShortcutIndex(_ event: NSEvent) -> Int? {
        switch event.charactersIgnoringModifiers {
        case "1": return 0
        case "2": return 1
        case "3": return 2
        default: return nil
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

struct CanvasKeyboardCycleMonitor: NSViewRepresentable {
    @ObservedObject var store: WhiteboardStore

    func makeNSView(context: Context) -> CanvasKeyboardCycleHostView {
        let view = CanvasKeyboardCycleHostView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: CanvasKeyboardCycleHostView, context: Context) {
        nsView.store = store
        nsView.attachIfNeeded()
    }
}
