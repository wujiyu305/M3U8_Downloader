import SwiftUI

/// Sheet for choosing which tracks to download.
///
/// Mirrors what the CLI does when no selection is given — it opens an interactive
/// multi-select prompt. That prompt cannot run as a child process with a piped
/// stdout (it crashes mid-render), so the app parses the engine's stream list and
/// asks here instead.
struct StreamSelectionView: View {
    let catalog: StreamCatalog
    /// Track IDs the user has ticked.
    @Binding var selection: Set<String>
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                section(for: .video, title: "Video", systemImage: "film")
                section(for: .audio, title: "Audio", systemImage: "waveform")
                section(for: .subtitle, title: "Subtitles", systemImage: "captions.bubble")
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .frame(width: 640, height: 520)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose tracks to download")
                .font(.headline)
            Text(
                "\(catalog.video.count) video · \(catalog.audio.count) audio · "
                    + "\(catalog.subtitles.count) subtitle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(
        for kind: MediaStream.Kind,
        title: String,
        systemImage: String
    ) -> some View {
        let streams = catalog.streams.filter { $0.kind == kind }
        if !streams.isEmpty {
            Section {
                ForEach(streams) { stream in
                    row(stream)
                }
            } header: {
                HStack {
                    Label(title, systemImage: systemImage)
                    Spacer()
                    // Bulk toggles: with a dozen video renditions, ticking them one
                    // at a time is tedious.
                    Button(allSelected(streams) ? "None" : "All") {
                        toggleAll(streams)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private func row(_ stream: MediaStream) -> some View {
        let presentation = stream.presentation
        return Toggle(isOn: binding(for: stream)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    ForEach(presentation.tags, id: \.self) { tag in
                        TagChip(text: tag)
                    }
                }
                // What makes an otherwise identical-looking track distinct: bitrate,
                // frame rate and the exact codec string for video, the group for the rest.
                if let detail = presentation.detail {
                    Text(detail)
                        .font(
                            .system(
                                .caption,
                                design: stream.kind == .video ? .monospaced : .default)
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 1)
    }

    private func binding(for stream: MediaStream) -> Binding<Bool> {
        Binding(
            get: { selection.contains(stream.id) },
            set: { isOn in
                if isOn {
                    selection.insert(stream.id)
                } else {
                    selection.remove(stream.id)
                }
            }
        )
    }

    private func allSelected(_ streams: [MediaStream]) -> Bool {
        !streams.isEmpty && streams.allSatisfy { selection.contains($0.id) }
    }

    private func toggleAll(_ streams: [MediaStream]) {
        if allSelected(streams) {
            for stream in streams { selection.remove(stream.id) }
        } else {
            for stream in streams { selection.insert(stream.id) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Some subsets cannot be expressed as engine filters. Saying so beats
            // downloading tracks the user did not pick.
            ForEach(inexpressible, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Download", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty || !inexpressible.isEmpty)
            }
        }
        .padding(12)
    }

    private var selectionSummary: String {
        guard !selection.isEmpty else { return "Nothing selected" }
        let chosen = catalog.streams.filter { selection.contains($0.id) }
        let counts = MediaStream.Kind.allCases.compactMap { kind -> String? in
            let n = chosen.filter { $0.kind == kind }.count
            return n > 0 ? "\(n) \(kind.rawValue)" : nil
        }
        return counts.joined(separator: " · ")
    }

    /// Human-readable explanations for any kind whose selection cannot be turned
    /// into an exact filter.
    private var inexpressible: [String] {
        catalog.filters(for: selection).compactMap { filter in
            guard case .inexpressible(let kind, let extra) = filter else { return nil }
            let names = extra.prefix(3).map(\.summary).joined(separator: ", ")
            let more = extra.count > 3 ? " and \(extra.count - 3) more" : ""
            return
                "This combination of \(kind.rawValue) tracks cannot be requested precisely — "
                + "it would also download: \(names)\(more). Pick tracks that differ in only one "
                + "attribute, or select them all."
        }
    }
}

/// A short label next to a track's title: its codec, dynamic range, channel layout or language.
private struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}

#Preview {
    @Previewable @State var selection: Set<String> = []
    let json = """
        [
          {"Url":"https://a/v1","Resolution":"3840x2160","Codecs":"hvc1.2.20000000.H150.B0","Bandwidth":12626963,"FrameRate":29.97,"VideoRange":"SDR"},
          {"Url":"https://a/v2","Resolution":"1920x1080","Codecs":"avc1.640028","Bandwidth":6499000,"FrameRate":29.97,"VideoRange":"SDR"},
          {"Url":"https://a/v3","Resolution":"640x360","Codecs":"avc1.64001e","Bandwidth":803000,"FrameRate":29.97,"VideoRange":"SDR"},
          {"Url":"https://a/a1","MediaType":"AUDIO","GroupId":"16ch","Language":"en","Name":"English Audio","Channels":"16/JOC"},
          {"Url":"https://a/a2","MediaType":"AUDIO","GroupId":"2ch","Language":"en","Name":"English Audio","Channels":"2"},
          {"Url":"https://a/s1","MediaType":"SUBTITLES","GroupId":"subtitles","Language":"en","Name":"English"}
        ]
        """
    let catalog = try! StreamCatalog.parse(metaJSON: Data(json.utf8))
    return StreamSelectionView(
        catalog: catalog,
        selection: $selection,
        onCancel: {},
        onConfirm: {}
    )
}
