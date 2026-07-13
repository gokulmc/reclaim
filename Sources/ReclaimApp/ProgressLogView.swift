import SwiftUI

/// Live, monospaced, auto-scrolling progress log. `fstrim` is slow and silent until it's
/// done (SPEC.md §7), so users need to see something moving — this is that something.
struct ProgressLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            .onChange(of: lines.count) { _ in
                guard let lastIndex = lines.indices.last else { return }
                withAnimation {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
    }
}
