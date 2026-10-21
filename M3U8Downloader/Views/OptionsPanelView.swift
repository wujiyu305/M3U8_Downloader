import SwiftUI

/// Editor for a single download's options.
///
/// Grouped the same way as the engine's own help output and the web generator's
/// tabs, so someone familiar with either can find things. Only the options that
/// are useful from a GUI are surfaced; the rest remain reachable through the
/// "Extra arguments" field rather than being hidden behind a wall of controls.
///
/// The ffmpeg metadata pass used to be a section here. It is a top-level tab of its
/// own now (`MetadataPanelView`), because it operates on a file that already exists
/// rather than on this download — see `Core/AGENTS.md`.
struct OptionsPanelView: View {
    @Binding var options: DownloadOptions
    /// Return pressed in the URL field; see `StreamURLField.onSubmit`.
    var onSubmitURL: () -> Void = {}

    /// Sections start collapsed apart from the essentials, so the panel opens on
    /// what most downloads actually need.
    @State private var expandedSections: Set<Section> = [.output]

    enum Section: String, CaseIterable, Identifiable {
        case output = "Output"
        case network = "Network"
        case selection = "Tracks"
        case merge = "Merge & Decrypt"
        case live = "Live"
        case advanced = "Advanced"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .output: return "folder"
            case .network: return "network"
            case .selection: return "slider.horizontal.3"
            case .merge: return "film.stack"
            case .live: return "dot.radiowaves.left.and.right"
            case .advanced: return "gearshape"
            }
        }

        /// A distinct tint per section, so the eye can find a section by colour
        /// while scrolling rather than re-reading every header.
        var tint: Color {
            switch self {
            case .output: return .blue
            case .network: return .teal
            case .selection: return .indigo
            case .merge: return .purple
            case .live: return .pink
            case .advanced: return .gray
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StreamURLField(text: $options.input, onSubmit: onSubmitURL)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            form
        }
    }

    private var form: some View {
        Form {
            ForEach(Section.allCases) { section in
                SwiftUI.Section {
                    if expandedSections.contains(section) {
                        content(for: section)
                    }
                } header: {
                    PanelDisclosureHeader(
                        title: section.rawValue,
                        systemImage: section.systemImage,
                        tint: section.tint,
                        isExpanded: expandedSections.contains(section)
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            if expandedSections.contains(section) {
                                expandedSections.remove(section)
                            } else {
                                expandedSections.insert(section)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func content(for section: Section) -> some View {
        switch section {
        case .output: outputSection
        case .network: networkSection
        case .selection: selectionSection
        case .merge: mergeSection
        case .live: liveSection
        case .advanced: advancedSection
        }
    }

    // MARK: - Output

    /// Where the files go. The stream URL is deliberately not here: it is the one required
    /// field, so it sits above the form as `StreamURLField` rather than being the first of
    /// several identical-looking rows.
    private var outputSection: some View {
        Group {
            OptionalTextField(
                "Save name",
                text: $options.basic.saveName,
                prompt: "Taken from the link"
            )
            DirectoryField(
                label: "Save to",
                path: $options.basic.saveDirectory,
                placeholder: "Downloads"
            )
            DirectoryField(
                label: "Temporary files",
                path: $options.basic.tempDirectory,
                placeholder: "Alongside the output"
            )
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Group {
            HeaderListEditor(headers: $options.network.headers)

            OptionalIntField(
                label: "Threads",
                value: $options.network.threadCount,
                // The engine defaults to the core count, which varies by machine,
                // so the placeholder states that rather than a fixed number.
                placeholder: "\(ProcessInfo.processInfo.activeProcessorCount) (this Mac's cores)",
                range: 1...256
            )
            OptionalIntField(
                label: "Retries",
                value: $options.network.downloadRetryCount,
                placeholder: "3",
                range: 0...100
            )
            OptionalTextField(
                "Speed limit",
                text: $options.network.maxSpeed,
                prompt: "e.g. 15M or 500K"
            )
            OptionalTextField(
                "Proxy",
                text: $options.network.customProxy,
                prompt: "http://127.0.0.1:8080"
            )
            TristateToggle(
                label: "Use system proxy",
                value: $options.network.useSystemProxy,
                engineDefault: true
            )
        }
    }

    // MARK: - Tracks

    private var selectionSection: some View {
        Group {
            TristateToggle(
                label: "Auto-select best tracks",
                value: $options.selection.autoSelect,
                engineDefault: false
            )
            OptionalTextField(
                "Video filter",
                text: $options.selection.selectVideo,
                prompt: "e.g. best or res=\"1080*\""
            )
            OptionalTextField(
                "Audio filter",
                text: $options.selection.selectAudio,
                prompt: "e.g. best or lang=en"
            )
            OptionalTextField(
                "Subtitle filter",
                text: $options.selection.selectSubtitle,
                prompt: "e.g. all"
            )

            Picker("Subtitle format", selection: $options.selection.subtitleFormat) {
                Text("SRT (default)").tag(SubtitleFormat?.none)
                ForEach(SubtitleFormat.allCases, id: \.self) { format in
                    Text(format.rawValue).tag(SubtitleFormat?.some(format))
                }
            }

            TristateToggle(
                label: "Subtitles only",
                value: $options.selection.subtitleOnly,
                engineDefault: false
            )
        }
    }

    // MARK: - Merge and decryption

    private var mergeSection: some View {
        Group {
            Toggle(
                "Merge into a single file after download",
                isOn: Binding(
                    get: { options.merge.muxAfterDone != nil },
                    set: { enabled in
                        options.merge.muxAfterDone = enabled ? MuxAfterDone() : nil
                    }
                )
            )

            if let mux = options.merge.muxAfterDone {
                Picker(
                    "Container",
                    selection: Binding(
                        get: { mux.format },
                        set: { options.merge.muxAfterDone?.format = $0 }
                    )
                ) {
                    ForEach(MuxFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker(
                    "Muxer",
                    selection: Binding(
                        get: { mux.muxer },
                        set: { options.merge.muxAfterDone?.muxer = $0 }
                    )
                ) {
                    ForEach(Muxer.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle(
                    "Keep the pre-merge files",
                    isOn: Binding(
                        get: { mux.keep },
                        set: { options.merge.muxAfterDone?.keep = $0 }
                    )
                )

                // mkvmerge cannot write MP4. The engine's own guard misses the
                // uppercase spelling, so this is caught here instead of failing
                // deep into the run.
                if let message = mux.validationMessage {
                    IssueLabel(message: message)
                }
            }

            TristateToggle(
                label: "Delete temporary files when done",
                value: $options.merge.deleteAfterDone,
                engineDefault: true
            )

            KeyListEditor(keys: $options.merge.keys)

            Picker("Decryption engine", selection: $options.merge.decryptionEngine) {
                Text("mp4decrypt (default)").tag(DecryptEngine?.none)
                ForEach(DecryptEngine.allCases, id: \.self) { engine in
                    Text(engine.rawValue).tag(DecryptEngine?.some(engine))
                }
            }
        }
    }

    // MARK: - Live

    private var liveSection: some View {
        Group {
            TristateToggle(
                label: "Treat a live stream as video on demand",
                value: $options.live.performAsVOD,
                engineDefault: false
            )
            TristateToggle(
                label: "Merge segments in real time",
                value: $options.live.realTimeMerge,
                engineDefault: false
            )
            OptionalTextField(
                "Record limit",
                text: $options.live.recordLimit,
                prompt: "HH:mm:ss"
            )
            OptionalIntField(
                label: "Wait time",
                value: $options.live.waitTime,
                placeholder: "seconds",
                range: 0...86400
            )
            TristateToggle(
                label: "Keep segments after merging",
                value: $options.live.keepSegments,
                engineDefault: true
            )
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Group {
            Picker("Log level", selection: $options.advanced.logLevel) {
                Text("INFO (default)").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(LogLevel?.some(level))
                }
            }
            TristateToggle(
                label: "Download tracks concurrently",
                value: $options.advanced.concurrentDownload,
                engineDefault: false
            )
            TristateToggle(
                label: "Write meta JSON",
                value: $options.advanced.writeMetaJSON,
                engineDefault: true
            )
            TristateToggle(
                label: "Check segment count",
                value: $options.advanced.checkSegmentsCount,
                engineDefault: true
            )
            OptionalTextField(
                "Base URL",
                text: $options.advanced.baseURL,
                prompt: "Rewrite relative segment URLs"
            )

            // An escape hatch for the ~40 options this panel does not surface, so
            // the GUI never becomes a hard ceiling on what the engine can do.
            ExtraArgumentsField(arguments: $options.extraArguments)
        }
    }
}

#Preview {
    @Previewable @State var options: DownloadOptions = {
        var options = DownloadOptions()
        options.input = "https://example.com/stream.m3u8"
        return options
    }()

    OptionsPanelView(options: $options)
        .frame(width: 460, height: 620)
}
