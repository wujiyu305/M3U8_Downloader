import Foundation

/// Builds the ffmpeg argument vector for the optional metadata pass.
///
/// Ported from the web generator's Metadata tab (`frontend.html`), with the same
/// argument order, because ffmpeg is order-sensitive: `-i` inputs must precede the
/// `-map`/`-c` options that refer to them, and the output path must come last.
///
/// As with `CommandBuilder`, this produces an argv for `Process` and never a shell
/// string, so titles containing quotes or `$` need no escaping and cannot become
/// command execution.
nonisolated enum MetadataCommandBuilder {

    /// Builds the argv. Inputs are numbered in the order they are added: the media
    /// file is always input 0 and the cover, when present, input 1.
    static func arguments(for options: MetadataOptions) -> [String] {
        var argv: [String] = []

        guard !options.inputPath.isEmpty else { return argv }
        argv += ["-i", options.inputPath]

        let hasCover = !(options.coverImagePath ?? "").isEmpty
        if hasCover, let cover = options.coverImagePath {
            argv += ["-i", cover]
        }

        if let title = options.title, !title.isEmpty {
            argv += ["-metadata", "title=\(title)"]
        }
        if let description = options.description, !description.isEmpty {
            argv += ["-metadata", "description=\(description)"]
        }
        if let date = options.date, !date.isEmpty {
            argv += ["-metadata", "date=\(date)"]
        }

        // Keep every stream from the media file, including subtitles and multiple
        // audio tracks. `-map 0` rather than the default stream selection, which
        // would silently pick one stream per type and drop the rest — the whole
        // point of this pass is to preserve what the download produced.
        argv += ["-map", "0"]

        if hasCover, let cover = options.coverImagePath {
            // Attach the cover as a second video stream flagged as artwork.
            argv += ["-map", "1:v"]
            argv += ["-c", "copy"]
            // The cover must be re-encoded to a codec the container accepts as
            // attached artwork; copying an arbitrary input image can produce a file
            // players refuse to show a thumbnail for.
            argv += ["-c:v:1", coverCodec(forPath: cover)]
            argv += ["-disposition:v:1", "attached_pic"]
        } else {
            argv += ["-c", "copy"]
        }

        if !options.outputPath.isEmpty {
            argv.append(options.outputPath)
        }
        return argv
    }

    /// JPEG stays JPEG; anything else is written as PNG.
    ///
    /// Matches the web generator's behaviour, which only distinguishes these two.
    static func coverCodec(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return (ext == "jpg" || ext == "jpeg") ? "mjpeg" : "png"
    }

    /// A default output path derived from the input, so the pass never silently
    /// overwrites the file it is reading.
    ///
    /// ffmpeg cannot read and write the same file in one invocation: it truncates
    /// the output on open, so an in-place run destroys the input before reading it.
    static func suggestedOutputPath(forInput input: String) -> String {
        guard !input.isEmpty else { return "" }
        let url = URL(fileURLWithPath: input)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        let name = ext.isEmpty ? "\(base)_meta" : "\(base)_meta.\(ext)"
        return directory.appendingPathComponent(name).path
    }

    // MARK: - Validation

    struct Issue: Equatable, Identifiable {
        enum Field: Equatable {
            case input
            case output
            case sameInputAndOutput
        }
        var id: String { "\(field)" }
        let field: Field
        let message: String
    }

    static func validate(_ options: MetadataOptions) -> [Issue] {
        var issues: [Issue] = []

        if options.inputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(field: .input, message: "An input file is required."))
        }
        if options.outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(field: .output, message: "An output file is required."))
        }

        // Refuse in-place rewriting: ffmpeg truncates the output as it opens it, so
        // this would destroy the input rather than fail cleanly.
        if !options.inputPath.isEmpty, !options.outputPath.isEmpty {
            let input = URL(fileURLWithPath: options.inputPath).standardizedFileURL
                .resolvingSymlinksInPath()
            let output = URL(fileURLWithPath: options.outputPath).standardizedFileURL
                .resolvingSymlinksInPath()
            if input == output {
                issues.append(
                    Issue(
                        field: .sameInputAndOutput,
                        message:
                            "The output must differ from the input: ffmpeg truncates the output "
                            + "file as it opens it, which would destroy the source."
                    )
                )
            }
        }
        return issues
    }
}
