import SwiftUI

/// Entry point: a single `MenuBarExtra` scene in `.window` style (locked UI-style decision,
/// docs/IMPLEMENTATION.md) — the status item label plus a native detail panel, no separate
/// windows or Dock presence (Dock/agent behavior is controlled by `LSUIElement` in the
/// packaged app's Info.plist; see build.sh).
@main
struct ReclaimApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            DetailPanelView()
                .environmentObject(appState)
        } label: {
            MenuBarLabelView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
