import SwiftUI

/// The strip across the top of the window that says the engine or ffmpeg is missing.
///
/// 🔴 **One line, with the instructions behind a button.** It used to carry the recovery
/// text (`Build it from… ./scripts/build-engine.sh … or set a path in Settings`) as a
/// multi-line `Text` with `fixedSize(horizontal: false, vertical: true)` inside an
/// `HStack(alignment: .top)`. In a Release build that made the banner's ideal height
/// enormous: the window's content was laid out roughly 1 400 pt too tall, so the whole pane
/// slid up under the toolbar and the URL field, the action bar and the log were out of
/// sight. It never showed in development, because the engine is embedded there and no banner
/// appears; it showed in an archive built without the engine, and would for anyone without
/// ffmpeg.
///
/// Found by building Release without the engine and capturing the window, then replacing the
/// banner piece by piece: a plain 97 pt spacer in its place was fine, an overlay was fine, a
/// `fixedSize` banner made it worse, and this single-row version fixed it. `ToolBannerTests`
/// pins its height.
struct ToolBanner: View {
    let title: String
    /// Longer instructions, shown on request.
    let hasDetail: Bool
    let systemImage: String
    let tint: Color
    let onShowDetail: () -> Void
    let onCheckAgain: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            if hasDetail {
                Button("How to fix", action: onShowDetail)
                    .controlSize(.small)
            }
            Button("Check again", action: onCheckAgain)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.28))
        )
        .padding([.horizontal, .top], 16)
    }
}

#Preview("Engine missing") {
    ToolBanner(
        title: "The N_m3u8DL-RE download engine was not found.",
        hasDetail: true, systemImage: "exclamationmark.octagon.fill", tint: .red,
        onShowDetail: {}, onCheckAgain: {}
    )
    .frame(width: 630)
}

#Preview("ffmpeg not executable") {
    ToolBanner(
        title: "ffmpeg at /nonexistent/ffmpeg is not executable.",
        hasDetail: true, systemImage: "exclamationmark.triangle.fill", tint: .orange,
        onShowDetail: {}, onCheckAgain: {}
    )
    .frame(width: 630)
}
