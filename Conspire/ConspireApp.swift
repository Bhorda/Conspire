//
//  ConspireApp.swift
//  Conspire
//

import SwiftData
import SwiftUI

@main
struct ConspireApp: App {
    @AppStorage("showDebugHUD") private var showDebugHUD: Bool = false

    /// The store lives at an explicit, app-specific path.
    ///
    /// SwiftData's default for an unsandboxed app is
    /// `~/Library/Application Support/default.store`, which is *not* namespaced by
    /// bundle identifier — so two unsandboxed SwiftData apps share one file and
    /// destroy each other's data when the schemas disagree. Naming the store
    /// ourselves makes that impossible, sandboxed or not.
    private static let sharedContainer: ModelContainer = {
        let directory = URL.applicationSupportDirectory
            .appending(path: "Conspire", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = ModelConfiguration(
            url: directory.appending(path: "Conspire.store")
        )
        do {
            return try ModelContainer(
                for: BoardEntity.self, NoteEntity.self, NoteGroupEntity.self,
                     LinkEntity.self, FieldEntity.self,
                configurations: configuration
            )
        } catch {
            fatalError("Could not open the Conspire store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(Self.sharedContainer)
        .commands {
            CommandMenu("Developer") {
                Toggle("Show Debug HUD", isOn: $showDebugHUD)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
