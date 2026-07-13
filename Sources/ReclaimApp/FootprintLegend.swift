import SwiftUI

/// One entry in the Docker-footprint legend under the stack-bar.
struct FootprintLegendItem: Identifiable {
    let id = UUID()
    let color: Color
    let name: String
    let value: Int64
}

/// The legend row under the stack-bar (matches `.legend` in panel.html) — a color dot + name +
/// bold tabular value per non-zero category, wrapping to a new line if the panel is narrow.
struct FootprintLegend: View {
    let items: [FootprintLegendItem]

    var body: some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    (
                        Text("\(item.name) ")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        + Text(appFormatBytes(item.value))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    )
                }
            }
        }
    }
}

/// A minimal left-to-right, top-to-bottom wrapping layout — used only for the footprint legend,
/// which needs to wrap onto a second line when "Containers" is present alongside the other
/// three categories inside the 320pt panel. Stock SwiftUI `Layout` protocol (macOS 13+), no
/// external dependency.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > maxWidth {
                totalHeight += currentLineHeight + lineSpacing
                currentX = 0
                currentLineHeight = 0
            }
            currentX += size.width + spacing
            currentLineHeight = max(currentLineHeight, size.height)
        }
        totalHeight += currentLineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : currentX, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var currentLineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX, currentX + size.width > bounds.maxX {
                currentY += currentLineHeight + lineSpacing
                currentX = bounds.minX
                currentLineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            currentLineHeight = max(currentLineHeight, size.height)
        }
    }
}
