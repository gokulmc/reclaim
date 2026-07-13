import SwiftUI

/// The always-visible status item label: the Concept-A `MenuBarIcon` glyph (state-tinted)
/// plus the current host free-space text (docs/IMPLEMENTATION.md, App M1-M4).
struct MenuBarLabelView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Label {
            Text(appState.freeSpaceText)
        } icon: {
            Image(nsImage: MenuBarIcon.image(tint: appState.diskLevel.nsColor))
        }
    }
}
