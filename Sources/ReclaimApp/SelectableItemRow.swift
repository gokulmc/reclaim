import SwiftUI

/// A leading checkbox (`.ck` / `.ck.on` / `.ck.off` in docs/design/caches-section.html) in
/// front of the existing `ItemRow`, bound to a `Binding<Bool>`. `ItemRow` itself — and all of
/// its current call sites (`DetailPanelView`'s Docker "Safe to clear" / "Protected" rows) — are
/// left completely unchanged; this is a pure wrapper used only by the cache selection UI
/// (`CacheSectionView`, M3b).
struct SelectableItemRow: View {
    @Binding var isOn: Bool
    let emoji: String
    let chipTint: Color
    let name: String
    let description: String
    let size: Int64
    let tagText: String
    let tagForeground: Color
    let tagBackground: Color

    var body: some View {
        HStack(spacing: 0) {
            CacheCheckbox(isOn: $isOn)
                .padding(.leading, 11)
            ItemRow(
                emoji: emoji,
                chipTint: chipTint,
                name: name,
                description: description,
                size: size,
                tagText: tagText,
                tagForeground: tagForeground,
                tagBackground: tagBackground
            )
        }
    }
}

/// The lighter-weight per-app child row (`.app` in the design card): just a name + size, no
/// chip/description/tag — `~/Library/Caches` can fan out into dozens of these, so the design
/// deliberately keeps them visually quieter than the top-level tool rows above.
struct SelectableAppCacheRow: View {
    @Binding var isOn: Bool
    let name: String
    let size: Int64

    var body: some View {
        HStack(spacing: 9) {
            CacheCheckbox(isOn: $isOn)
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Text(appFormatBytes(size))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 26)
        .padding(.trailing, 11)
        .padding(.vertical, 3)
    }
}

/// The checkbox control itself (shared by both row flavors above): a filled circle + checkmark
/// when on, tinted `Palette.ctaFill` — the same blue the design card's `.ck.on` uses — and a
/// plain dimmed outline circle when off. Internal (not `private`) so M4b's per-image rows in
/// `DetailPanelView` can reuse the exact same control for the "Remove specific images…"
/// disclosure rather than redrawing the checkbox glyph themselves.
struct CacheCheckbox: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isOn ? Palette.ctaFill : Color.secondary.opacity(0.45))
        }
        .buttonStyle(.plain)
    }
}
