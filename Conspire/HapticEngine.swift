//
//  HapticEngine.swift
//  Conspire
//

#if os(macOS)
import AppKit

enum HapticEngine {
    static func light() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    static func strong() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
#else
enum HapticEngine {
    static func light() {}
    static func strong() {}
}
#endif
