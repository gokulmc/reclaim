import SwiftUI

/// One itemised row (matches `.row` in panel.html): a 28pt tinted-square emoji chip, a
/// name+size line, a description line, and a tag pill on the trailing edge.
struct ItemRow: View {
    let emoji: String
    let chipTint: Color
    let name: String
    let description: String
    let size: Int64
    let tagText: String
    let tagForeground: Color
    let tagBackground: Color

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(chipTint.opacity(0.16))
                Text(emoji).font(.system(size: 14))
            }
            .frame(width: 28, height: 28)

            // Name + description take all remaining width so names never truncate against
            // the size/tag; the size and tag stack in a fixed trailing column.
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(appFormatBytes(size))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                TagView(text: tagText, foreground: tagForeground, background: tagBackground)
            }
            .fixedSize()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 11)
    }
}

/// A small pill (matches `.tag` in panel.html) — 9.5pt bold text, tinted background, radius 5.
struct TagView: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(foreground)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(background))
            .fixedSize()
    }
}
