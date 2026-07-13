import SwiftUI

/// One colored segment of a `StackBarView`.
struct StackBarSegment {
    let color: Color
    let value: Int64
}

/// The Docker-footprint stack-bar (matches `.stackbar` in panel.html): a 6pt-tall, fully
/// rounded track split proportionally across up to four colored segments. Zero-size segments
/// collapse entirely rather than drawing a hairline sliver.
struct StackBarView: View {
    let segments: [StackBarSegment]

    private var total: Int64 {
        max(segments.reduce(0) { $0 + $1.value }, 1)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.value > 0 {
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: geo.size.width * CGFloat(segment.value) / CGFloat(total))
                    }
                }
            }
        }
        .frame(height: 6)
        .background(Color.secondary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
