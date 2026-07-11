import AppKit
import SwiftUI

@main
struct HerdrMenubarApp: App {
    var body: some Scene {
        MenuBarExtra("Herdr", systemImage: "circle") {
            Text("Herdr Menubar")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
