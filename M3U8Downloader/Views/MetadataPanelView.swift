import SwiftUI

/// Editor for a standalone ffmpeg metadata pass.
///
/// A top-level tab rather than a section of the download options, mirroring the web
/// generator's own Download / Metadata split: the pass works on a file that already
/// exists, so tying it to a download would have meant it could only ever be applied
/// to something this app had just fetched.
///
/// That split also removed a whole class of bug. While this was an optional
/// sub-form of the download panel, its "enabled but no paths yet" state fed
/// `ContentView.validationIssues` and disabled the **Download** button — a control
/// on the other side of the window from the fields responsible. Now its problems
/// only ever disable its own button, which sits directly under the fields.
struct MetadataPanelView: View {
    @Binding var metadata: MetadataOptions

    var body: some View {
        Form {
            Section {
                FileField(
                    label: "Input file",
                    path: Binding(
                        get: { metadata.inputPath },
                        set: { newValue in
                            metadata.inputPath = newValue
                            // Suggest an output next to the input rather than
                            // leaving it blank: ffmpeg cannot write to its own
                            // input, so a default that differs avoids the mistake.
                            if metadata.outputPath.isEmpty {
                                metadata.outputPath =
                                    MetadataCommandBuilder.suggestedOutputPath(forInput: newValue)
                            }
                        }
                    )
                )
                FileField(
                    label: "Output file",
                    path: $metadata.outputPath
                )
                FieldFootnote(
                    "The output must be a different file: ffmpeg truncates it as it opens it, "
                        + "so writing in place would destroy the source."
                )
            } header: {
                PanelSectionHeader(title: "Files", systemImage: "folder", tint: .blue)
            }

            Section {
                OptionalTextField(
                    "Title",
                    text: $metadata.title,
                    prompt: "Shown by players and Finder"
                )
                OptionalTextField(
                    "Description",
                    text: $metadata.description
                )
                OptionalTextField(
                    "Date",
                    text: $metadata.date,
                    prompt: "e.g. 2026-01-31"
                )
            } header: {
                PanelSectionHeader(title: "Fields", systemImage: "textformat", tint: .indigo)
            }

            Section {
                FileField(
                    label: "Cover image",
                    path: Binding(
                        // Stored as nil when empty, so an image the user chose and
                        // then cleared does not linger as a blank ffmpeg input.
                        get: { metadata.coverImagePath ?? "" },
                        set: { metadata.coverImagePath = $0.isEmpty ? nil : $0 }
                    )
                )
                if let cover = metadata.coverImagePath, !cover.isEmpty {
                    LabeledContent("Written as") {
                        Text(MetadataCommandBuilder.coverCodec(forPath: cover))
                            .font(.system(.body, design: .monospaced))
                    }
                    FieldFootnote(
                        "Attached as artwork, re-encoded from the file's extension: JPEG stays "
                            + "JPEG, anything else becomes PNG."
                    )
                }
            } header: {
                PanelSectionHeader(title: "Artwork", systemImage: "photo", tint: .orange)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Empty") {
    @Previewable @State var metadata = MetadataOptions()

    MetadataPanelView(metadata: $metadata)
        .frame(width: 460, height: 520)
}

#Preview("Filled in") {
    @Previewable @State var metadata: MetadataOptions = {
        var metadata = MetadataOptions()
        metadata.inputPath = "/Users/me/Movies/episode-1.mp4"
        metadata.outputPath = "/Users/me/Movies/episode-1_meta.mp4"
        metadata.coverImagePath = "/Users/me/Pictures/cover.jpg"
        metadata.title = "My Show"
        metadata.description = "Episode 1"
        return metadata
    }()

    MetadataPanelView(metadata: $metadata)
        .frame(width: 460, height: 520)
}
