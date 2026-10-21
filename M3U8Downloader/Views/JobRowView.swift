import SwiftUI

/// One row in the queue: name, state, progress and the controls for that job.
///
/// Laid out for the trailing inspector column, which is around 330pt wide. Every
/// caption is therefore stacked and single-line-truncating rather than spread across
/// the row: an earlier version put segments, speed, ETA and the phase on one line with
/// a `Spacer`, which fits a full-width detail pane and collapses into unreadable
/// fragments here.
struct JobRowView: View {
    let job: DownloadJob
    let onStart: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    /// Opens whichever decision the job is blocked on.
    var onResolve: () -> Void = {}
    /// Highlights a finished job's output in Finder.
    var onReveal: () -> Void = {}
    /// Selects this job and opens the log drawer, which is collapsed by default.
    var onShowLog: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                stateIcon
                Text(job.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                controls
            }

            if job.kind == .metadata {
                kindBadge
                    // Aligned with the name rather than the row edge, so the badge
                    // reads as belonging to the title above it.
                    .padding(.leading, 24)
            }

            if job.state.isRunning {
                progressSection
            } else {
                statusLine
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Pieces

    private var stateIcon: some View {
        Group {
            switch job.state {
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .awaitingStreamSelection:
                // Blocked on the user, not on work: a spinner here would suggest
                // something is happening when nothing is.
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .cancelled:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .symbolRenderingMode(.hierarchical)
        .frame(width: 16)
    }

    /// Marks a metadata job, since the two kinds sit in one queue and otherwise look
    /// identical: both show a file name, a spinner and a duration.
    private var kindBadge: some View {
        Label("Metadata", systemImage: "tag")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(.quaternary)
            )
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if job.state.needsUserDecision {
                Button("Continue…", action: onResolve)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Remove", systemImage: "trash", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Discard this job")
            } else {
                if job.state.isRunning {
                    Button("Stop", systemImage: "stop.fill", action: onCancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(job.isStopping)
                        .help(job.isStopping ? "Stopping…" : "Stop this job")
                } else {
                    Button(
                        job.state.isTerminal ? "Retry" : "Start",
                        systemImage: "play.fill",
                        action: onStart
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(job.state.isTerminal ? "Run this job again" : "Start this job")
                }
                Button("Remove", systemImage: "trash", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove this job from the list")
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The bar tracks the mean across every stream, so it never walks backwards
            // when the engine moves on to the next track. The captions below carry the
            // active stream's own numbers.
            if let overall = job.overallPercent, overall > 0 {
                ProgressView(value: min(max(overall / 100, 0), 1))
                    .progressViewStyle(.linear)
            } else {
                // Indeterminate at 0%, and honest about it. The engine reports 0% for
                // the whole of a single-segment download whose server sends no
                // Content-Length; a bar pinned at zero for a minute is exactly what
                // made that look like an app bug. See `Progress.fraction`.
                ProgressView()
                    .progressViewStyle(.linear)
            }

            // Line one carries the numbers the CLI shows: how far along, how much has
            // arrived, how fast, how long is left.
            if let active = job.activeStream {
                HStack(spacing: 6) {
                    // Retry stays a separate view so it can be orange; folded into the
                    // string it would lose the only thing that makes it stand out.
                    if let retry = active.retryAttempt {
                        Text("retry \(retry)")
                            .foregroundStyle(.orange)
                    }
                    Text(Self.transferCaption(active, overallPercent: job.overallPercent))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Steady column widths, so a changing speed or size does not make the
                // line jitter sideways as it updates.
                .monospacedDigit()
            }

            Text(stageCaption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
        }
    }

    /// `35.0% · 8.20MB/23.43MB · 3.20MBps · ETA 00:01:12`, dropping whatever the engine
    /// has not reported yet.
    ///
    /// The percentage is the job's overall one so that it agrees with the bar; the size,
    /// rate and ETA are the active stream's, because per-stream is the only scope the
    /// engine reports them in.
    ///
    /// Ordered so that truncation in a narrow column loses the least useful part first:
    /// the percentage and the transferred size survive, the ETA is what goes.
    static func transferCaption(
        _ progress: EngineOutputParser.Progress,
        overallPercent: Double?
    ) -> String {
        var parts: [String] = [String(format: "%.1f%%", overallPercent ?? progress.percent)]
        if !progress.sizeText.isEmpty { parts.append(progress.sizeText) }
        if !progress.speedText.isEmpty { parts.append(progress.speedText) }
        // Only show an ETA once the engine has a real estimate; it prints "--:--:--"
        // until then.
        if progress.etaText != "--:--:--", !progress.etaText.isEmpty {
            parts.append("ETA \(progress.etaText)")
        }
        return parts.joined(separator: " · ")
    }

    /// Names the track being fetched, which is the one thing the overall bar cannot say:
    /// `Downloading · 1/3 · Vid 640x360 | 800 Kbps · 2/4 segments`.
    ///
    /// The counts are omitted when the engine is reporting bytes, or has not started the
    /// stream yet — see `Progress.segmentCounts`.
    private var stageCaption: String {
        var parts: [String] = [job.isStopping ? "Stopping…" : phaseDescription]
        if let position = job.activeStreamPosition {
            parts.append("\(position.index)/\(position.count)")
        }
        if let active = job.activeStream {
            if !active.streamDescription.isEmpty {
                parts.append(active.streamDescription)
            }
            if let counts = active.segmentCounts {
                parts.append("\(counts.completed)/\(counts.total) segments")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch job.state {
                case .queued:
                    Text(job.isWaitingForSlot ? "Waiting for the current job to finish" : "Queued")
                case .awaitingStreamSelection(let catalog):
                    Text(
                        "\(catalog.video.count) video · \(catalog.audio.count) audio · "
                            + "\(catalog.subtitles.count) subtitle — choose which to download"
                    )
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                case .succeeded:
                    Text(succeededText)
                case .cancelled:
                    Text("Stopped")
                case .failed(let failure):
                    Text(failure.message)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                case .running:
                    EmptyView()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            resultActions
        }
    }

    /// What to do next, once a job has stopped. A finished download used to leave the user
    /// to go and find the file; a failed one gave a single red line with no way to the log,
    /// which is collapsed by default.
    @ViewBuilder
    private var resultActions: some View {
        switch job.state {
        case .succeeded:
            Button("Show in Finder", systemImage: "magnifyingglass", action: onReveal)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.caption)
        case .failed:
            Button("Show Log", systemImage: "text.alignleft", action: onShowLog)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    private var succeededText: String {
        guard let duration = job.duration else { return "Finished" }
        return "Finished in \(Self.durationFormatter.string(from: duration) ?? "")"
    }

    /// No trailing ellipsis: this is joined into `progressCaption` ahead of the segment
    /// counts, where "Downloading… · 42/120" reads as a truncation rather than a list,
    /// and on its own it sits beside a moving progress bar that already says "busy".
    private var phaseDescription: String {
        guard case .running(let phase) = job.state else { return "" }
        switch phase {
        case .probingStreams: return "Listing tracks"
        case .starting: return "Starting"
        case .parsing: return "Parsing streams"
        case .downloading: return "Downloading"
        case .muxing: return "Combining tracks"
        case .applyingMetadata: return "Writing metadata"
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

#Preview("Running with progress") {
    var job = DownloadJob(
        options: {
            var options = DownloadOptions()
            options.input = "https://example.com/stream.m3u8"
            options.basic.saveName = "Episode 1"
            return options
        }())
    job.state = .running(.downloading)
    // Field values shaped exactly like a measured repaint:
    // `42/120 35.00% 8.20MB/23.43MB 3.20MBps 00:01:12`
    job.streamProgress = [
        EngineOutputParser.Progress(
            streamDescription: "Vid 1920x1080 | 4500 Kbps",
            completedSegments: 42,
            totalSegments: 120,
            percent: 35,
            retryAttempt: nil,
            sizeText: "8.20MB/23.43MB",
            speedText: "3.20MBps",
            etaText: "00:01:12"
        )
    ]
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}

#Preview("Several tracks, video first") {
    var job = DownloadJob(
        options: {
            var options = DownloadOptions()
            options.input = "https://example.com/master.m3u8"
            options.basic.saveName = "Episode 1"
            return options
        }())
    job.state = .running(.downloading)
    // One repaint of a real three-track job: the engine prints a row per stream, and
    // the ones it has not reached yet report Spectre's default `0/100`. Before these
    // were kept per stream, the subtitle row's 0% was what the window displayed.
    job.streamProgress = [
        EngineOutputParser.Progress(
            streamDescription: "Vid 640x360 | 800 Kbps",
            completedSegments: 2,
            totalSegments: 4,
            percent: 50,
            retryAttempt: nil,
            sizeText: "768.00KB/3.00MB",
            speedText: "256.00KBps",
            etaText: "00:00:02"
        ),
        EngineOutputParser.Progress(
            streamDescription: "Aud English Audio | en",
            completedSegments: 0,
            totalSegments: 100,
            percent: 0,
            retryAttempt: nil,
            sizeText: "",
            speedText: "",
            etaText: "--:--:--"
        ),
        EngineOutputParser.Progress(
            streamDescription: "Sub en | English",
            completedSegments: 0,
            totalSegments: 100,
            percent: 0,
            retryAttempt: nil,
            sizeText: "",
            speedText: "",
            etaText: "--:--:--"
        ),
    ]
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}

#Preview("Failed") {
    var job = DownloadJob(
        options: {
            var options = DownloadOptions()
            options.input = "https://example.com/broken.m3u8"
            return options
        }())
    job.state = .failed(.engineExited(code: 1, lastError: "Download first segment failed!"))
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}

#Preview("Retrying") {
    var job = DownloadJob(
        options: {
            var options = DownloadOptions()
            options.input = "https://example.com/flaky.m3u8"
            return options
        }())
    job.state = .running(.downloading)
    // The first repaint of a stalled download: the engine has no size to report yet,
    // so that field is `-` and arrives here empty.
    job.streamProgress = [
        EngineOutputParser.Progress(
            streamDescription: "Vid 640x360 | 800 Kbps",
            completedSegments: 0,
            totalSegments: 3,
            percent: 0,
            retryAttempt: 3,
            sizeText: "",
            speedText: "0.00Bps",
            etaText: "--:--:--"
        )
    ]
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}

#Preview("No usable percentage") {
    var job = DownloadJob(
        options: {
            var options = DownloadOptions()
            options.input = "https://example.com/chunked.m3u8"
            options.basic.saveName = "Chunked"
            return options
        }())
    job.state = .running(.downloading)
    // One segment, no Content-Length: the engine reports 0% for the whole download and
    // only the speed moves, so the bar must be indeterminate rather than frozen.
    job.streamProgress = [
        EngineOutputParser.Progress(
            streamDescription: "Vid 1280x720 | 2000 Kbps",
            completedSegments: 0,
            totalSegments: 1,
            percent: 0,
            retryAttempt: nil,
            sizeText: "",
            speedText: "585.94KBps",
            etaText: "--:--:--"
        )
    ]
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}

#Preview("Single-segment stream, counted in bytes") {
    var job = DownloadJob(
        options: {
            var options = DownloadOptions()
            options.input = "https://example.com/movie.mp4"
            options.basic.saveName = "Movie"
            return options
        }())
    job.state = .running(.downloading)
    // For a stream with one segment the engine overwrites the counts with byte
    // totals, so the row must not label them "segments".
    job.streamProgress = [
        EngineOutputParser.Progress(
            streamDescription: "Vid 1280x720 | 2000 Kbps",
            completedSegments: 12_345_678,
            totalSegments: 17_825_792,
            percent: 69.26,
            retryAttempt: nil,
            sizeText: "11.77MB/17.00MB",
            speedText: "2.40MBps",
            etaText: "00:00:02"
        )
    ]
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}

#Preview("Metadata job") {
    var job = DownloadJob(
        metadata: {
            var metadata = MetadataOptions()
            metadata.inputPath = "/Users/me/Movies/episode-1.mp4"
            metadata.outputPath = "/Users/me/Movies/episode-1_meta.mp4"
            metadata.title = "My Show"
            return metadata
        }())
    job.state = .running(.applyingMetadata)
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}

#Preview("Metadata job, finished") {
    var job = DownloadJob(
        metadata: {
            var metadata = MetadataOptions()
            metadata.inputPath = "/Users/me/Movies/episode-1.mp4"
            metadata.outputPath = "/Users/me/Movies/episode-1_meta.mp4"
            return metadata
        }())
    job.state = .succeeded
    job.startedAt = Date(timeIntervalSinceNow: -4)
    job.finishedAt = Date()
    return JobRowView(job: job, onStart: {}, onCancel: {}, onRemove: {})
        .padding()
        .frame(width: 330)
}
