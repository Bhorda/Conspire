//
//  InputModifiers.swift
//  Conspire
//

import Foundation
import AppKit


/// Shift / Command / Option held during a pointer action (macOS reads current event flags).
struct InputModifiers: Equatable, Sendable {
    var shift: Bool
    var command: Bool
    var option: Bool

    static let none = InputModifiers(shift: false, command: false, option: false)

    static func current() -> InputModifiers {
        let f = NSEvent.modifierFlags
        return InputModifiers(
            shift: f.contains(.shift),
            command: f.contains(.command),
            option: f.contains(.option)
        )
    }
//    #else
//    static func current() -> InputModifiers { .none }
}
