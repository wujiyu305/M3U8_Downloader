import AppKit
import SwiftUI

/// The stream URL field, given the prominence of the one thing every download needs.
///
/// It used to be the first row of a grouped `Form`, indistinguishable from "Save name" below
/// it: an empty field showed only its own label, so nothing said where to type. This is a
/// field you can find at a glance — larger, with its own placeholder, and with the two things
/// people actually do to fill it in: paste a link, or point at a manifest already on disk.
struct StreamURLField: View {
    @Binding var text: String
    /// Return pressed in this field. The caller decides whether that starts the download.
    ///
    /// Return used to reach the window's default button from *every* text field (save name,
    /// proxy, a header value), so editing any of them could start a download. Scoping it to
    /// this field keeps the one case where it is wanted — paste a link, press Return.
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.title3)
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)

            TextField(
                "URL or manifest path",
                text: $text,
                prompt: Text("Paste a stream URL or choose a file")
            )
            .textFieldStyle(.plain)
            .font(.system(.title3))
            .focused($isFocused)
            // One line: a URL never contains a newline, and a multi-line field would make
            // Return insert one instead of running the default action.
            .lineLimit(1)
            .truncationMode(.middle)
            .autocorrectionDisabled()
            .onSubmit { onSubmit() }

            trailingButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        // Ready to take a paste the moment the window opens.
        .onAppear { if text.isEmpty { isFocused = true } }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        if text.isEmpty {
            Button("Paste", systemImage: "doc.on.clipboard", action: paste)
                .help("Paste the link from the clipboard")
            Button("Choose…", systemImage: "folder", action: chooseFile)
                .help("Use a manifest file already on this Mac")
        } else {
            Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear")
        }
    }

    /// Trims on the way in. Links copied out of a chat or a terminal routinely carry a
    /// trailing newline or space, which the engine would take as part of the URL.
    private func paste() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        text = Self.cleaned(pasted)
    }

    nonisolated static func cleaned(_ pasted: String) -> String {
        pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
        }
    }
}

#Preview("Empty") {
    @Previewable @State var text = ""
    StreamURLField(text: $text)
        .padding(20)
        .frame(width: 640)
}

#Preview("Filled") {
    @Previewable @State var text =
        "https://events-delivery.apple.com/7297ElpSMNn2LZPPl9vkFV7w9WXbjB5s/m3u8/vod_main_JeyvV5ESJWYBatM.m3u8"
    StreamURLField(text: $text)
        .padding(20)
        .frame(width: 640)
}
