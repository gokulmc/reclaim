import SwiftUI

/// The always-visible status item label: an SF Symbol (state-dependent) plus the current host
/// free-space text (docs/IMPLEMENTATION.md, App M1-M4).
struct MenuBarLabelView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Label {
            Text(appState.freeSpaceText)
        } icon: {
            Image(systemName: appState.diskLevel.symbolName)
                .foregroundStyle(appState.diskLevel.color)
        }
    }
}
