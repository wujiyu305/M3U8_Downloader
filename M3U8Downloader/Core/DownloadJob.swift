import Foundation

/// One queued piece of work — a download, or a standalone ffmpeg metadata pass —
/// with its identity, configuration and observable state.
///
/// Deliberately a plain value type: the engine is driven by `DownloadCoordinator`,
/// and keeping state separate from the process machinery means the whole state
/// machine is testable without spawning anything.
nonisolated struct DownloadJob: Identifiable, Sendable {

    // MARK: - State

    enum State: Equatable, Sendable {
        case queued
        case running(Phase)
        /// Tracks were listed and the user has to choose. Mirrors what the CLI does
        /// with its interactive prompt, which cannot run as a child process.
        case awaitingStreamSelection(StreamCatalog)
        case succeeded
        /// Ended by the user. Distinct from `failed` because it is not a defect and
        /// should not be presented as an error.
        case cancelled
        case failed(Failure)

        var isTerminal: Bool {
            switch self {
            case .succeeded, .cancelled, .failed: return true
            case .queued, .running, .awaitingStreamSelection: return false
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        /// Whether the job is blocked on the user rather than on work.
        var needsUserDecision: Bool {
            if case .awaitingStreamSelection = self { return true }
            return false
        }
    }

    /// Coarse stage, driven by milestones in the engine's output. Progress
    /// percentages only mean something during `.downloading`.
    enum Phase: Equatable, Sendable {
        /// Listing the available tracks with `--skip-download`, before asking which
        /// to fetch.
        case probingStreams
        case starting
        case parsing
        case downloading
        case muxing
        /// The ffmpeg metadata pass — the only phase a metadata job goes through.
        case applyingMetadata
    }

    enum Failure: Equatable, Sendable {
        /// The engine ran and exited non-zero. `lastError` carries the most recent
        /// ERROR/WARN line, which is far more useful than the bare code.
        case engineExited(code: Int32, lastError: String?)
        case toolMissing(String)
        case launchFailed(String)
        case invalidOptions([String])
        /// ffmpeg failed while writing metadata.
        case metadataFailed(code: Int32, lastError: String?)
        /// Listing the available tracks failed, so there was nothing to choose from.
        case streamProbeFailed(String)
        /// The engine printed its own `Failed` verdict.
        ///
        /// A separate case from `engineExited` because there is **no** non-zero code to
        /// report: measured, a failed download still exits 0. See
        /// `EngineOutputParser.Verdict`.
        case engineReportedFailure(lastError: String?)

        var message: String {
            switch self {
            case .engineExited(let code, let lastError):
                if let lastError, !lastError.isEmpty { return Self.explained(lastError) }
                return "The download engine exited with code \(code)."
            case .toolMissing(let description): return description
            case .launchFailed(let description): return description
            case .invalidOptions(let issues):
                return issues.joined(separator: "\n")
            case .metadataFailed(let code, let lastError):
                if let lastError, !lastError.isEmpty {
                    return "Metadata pass failed: \(lastError)"
                }
                return "The metadata pass exited with code \(code)."
            case .streamProbeFailed(let description):
                return "Could not list the available tracks: \(description)"
            case .engineReportedFailure(let lastError):
                if let lastError, !lastError.isEmpty { return Self.explained(lastError) }
                return "The download engine reported the download as failed."
            }
        }

        /// The engine's own wording plus, for the one failure that is routinely not the
        /// user's doing, what to try.
        ///
        /// `Segment count check not pass, total: 774, downloaded: 773.` reads like a flaky
        /// connection, and a retry is the obvious response — but the same segment fails
        /// every time. Measured on an Apple event stream: the CDN answered one segment with
        /// `Content-Length: 2479526` and then closed the connection after **one byte**, for
        /// plain, HTTP/1.1, Range and cache-busted requests alike, and the engine's own
        /// retries (default 3, one second apart) could not change that. Only some variants of
        /// the stream were damaged, so choosing another one works. The pinned
        /// `--ui-language en-US` is what makes matching the English text reliable.
        static func explained(_ lastError: String) -> String {
            guard lastError.contains("Segment count check not pass") else { return lastError }
            return lastError
                + " A segment could not be downloaded in full. If the same one fails on every"
                + " attempt, the server's copy of it is damaged and retrying will not help."
                + " Choose a different stream, or turn off Check segment count under"
                + " Advanced to accept a result that is missing that segment."
        }
    }

    // MARK: - Identity and configuration

    let id: UUID
    /// The download to run, or `nil` for a metadata job — an ffmpeg pass over a
    /// file that already exists, with no engine run at all.
    ///
    /// Optional rather than a separate `kind` field so the two cannot disagree:
    /// there is exactly one place that says whether a download happens, and it is
    /// the same place that holds the arguments for it.
    var options: DownloadOptions?
    /// The ffmpeg metadata pass. For a metadata job this *is* the work; a download
    /// job leaves it `nil`.
    var metadata: MetadataOptions?

    /// Which of the two kinds of work this job represents. Derived, so it cannot
    /// drift out of step with the fields above.
    enum Kind: Equatable, Sendable {
        case download
        case metadata
    }

    var kind: Kind { options == nil ? .metadata : .download }

    // MARK: - Observable state

    var state: State = .queued
    /// One reading per stream the engine is reporting, in the order it first mentioned
    /// them — video, then audio, then subtitles, matching `SelectedSteams`.
    ///
    /// 🔴 **A job has as many of these as it has tracks, not one.** The engine runs a
    /// progress bar per selected stream and reprints all of them together with no
    /// separator between them, so a single `progress` field meant the last row of the
    /// table won: a job fetching video first displayed the *subtitle* task's 0% while
    /// the video was half done.
    var streamProgress: [EngineOutputParser.Progress] = []
    /// The engine's own closing judgement, once it has printed one.
    ///
    /// Held as state rather than re-derived from `log`, which is a bounded ring: the
    /// verdict is the one record that must never be lost to truncation.
    var engineVerdict: EngineOutputParser.Verdict?
    /// The save name the engine reported, which differs from `options.basic.saveName`
    /// whenever the user left that blank and the engine invented one.
    ///
    /// Held as state for the same reason as `engineVerdict`: the record that carries it is
    /// one of the first the engine prints, so on a long run it is the first to be dropped
    /// from the bounded `log`.
    var resolvedSaveName: String?
    /// The streams the engine said it would download, in order, with the size hints that
    /// weight the overall bar. Held as state, not read back from `log`: the list is printed
    /// once, at the start, and is the first thing a bounded log drops.
    var streamEstimates: [StreamEstimate] = []
    /// Between the engine's `Selected streams:` marker and the first line that is not a
    /// stream, where the lines being read are the selection rather than every extracted track.
    private var isReadingSelection = false
    /// Stop was requested and the process is still being brought down. Kept apart from
    /// `state` because the job really is still running until the process is gone, and a
    /// second Stop must not look possible.
    var isStopping = false
    /// Started while another job held the only slot, so it is queued to start by itself
    /// when that one ends. See `DownloadCoordinator.maximumConcurrentDownloads`.
    var isWaitingForSlot = false
    /// Bounded ring of recent output. Unbounded growth would be a slow leak on a
    /// long live recording, where the engine prints continuously for hours.
    var log: LogBuffer = LogBuffer()
    var startedAt: Date?
    var finishedAt: Date?
    /// Exact argv that was executed, so the UI can show what actually ran rather
    /// than re-deriving it and risking a mismatch.
    var executedCommand: String?

    /// Notes a log record that may carry the stream selection. Call for every record.
    ///
    /// English only, like the other message matches: `DownloadCoordinator.prepared` pins
    /// `--ui-language en-US`, and if the user overrides that the marker is missed and the
    /// overall bar falls back to default weights by kind, which is still far better than a
    /// plain average.
    mutating func noteSelection(_ record: EngineOutputParser.LogRecord) {
        if record.level == .info, record.message == "Selected streams:" {
            streamEstimates = []
            isReadingSelection = true
            return
        }
        guard isReadingSelection else { return }
        if let estimate = StreamEstimate.parse(record.message) {
            streamEstimates.append(estimate)
        } else {
            isReadingSelection = false
        }
    }

    /// Forgets what the previous run said about its streams.
    mutating func resetStreamEstimates() {
        streamEstimates = []
        isReadingSelection = false
    }

    /// Folds one repaint into the per-stream state, replacing that stream's previous
    /// reading rather than accumulating every repaint.
    mutating func record(_ progress: EngineOutputParser.Progress) {
        if let index = streamProgress.firstIndex(where: {
            $0.streamDescription == progress.streamDescription
        }) {
            streamProgress[index] = progress
        } else {
            streamProgress.append(progress)
        }
    }

    init(
        id: UUID = UUID(),
        options: DownloadOptions?,
        metadata: MetadataOptions? = nil
    ) {
        self.id = id
        self.options = options
        self.metadata = metadata
    }

    /// A metadata job: ffmpeg only, over a file the user already has.
    init(id: UUID = UUID(), metadata: MetadataOptions) {
        self.init(id: id, options: nil, metadata: metadata)
    }

    // MARK: - Derived

    /// A human-facing name, so a job is never nameless in the list.
    ///
    /// A download falls back to the input's last path component; a metadata job
    /// names itself after the file it *produces*, since that is the artefact the
    /// user is waiting for.
    var displayName: String {
        if let options {
            if let saveName = options.basic.saveName, !saveName.isEmpty { return saveName }
            guard let url = URL(string: options.input) else { return options.input }
            let last = url.lastPathComponent
            return last.isEmpty ? options.input : last
        }
        if let metadata {
            // Guarded against empty strings: `URL(fileURLWithPath: "")` resolves
            // against the current directory, so its last component would be some
            // unrelated directory name rather than nothing.
            for path in [metadata.outputPath, metadata.inputPath] where !path.isEmpty {
                let name = URL(fileURLWithPath: path).lastPathComponent
                if !name.isEmpty { return name }
            }
            return "Metadata"
        }
        return "Empty job"
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    // MARK: - Finding the result

    /// The directory this job writes into.
    ///
    /// A metadata job writes next to wherever its output path points; a download uses the
    /// chosen save directory, falling back to Downloads. See `OutputLocator`.
    var outputDirectory: URL? {
        if let options {
            return OutputLocator.directory(saveDirectory: options.basic.saveDirectory)
        }
        guard let metadata, !metadata.outputPath.isEmpty else { return nil }
        return URL(fileURLWithPath: metadata.outputPath).deletingLastPathComponent()
    }

    /// The files to highlight in Finder for a finished job.
    ///
    /// Empty when nothing can be identified with confidence, in which case the caller
    /// should open `outputDirectory` instead — showing the right folder beats selecting
    /// the wrong file.
    func outputFiles(fileManager: FileManager = .default) -> [URL] {
        if options == nil {
            // A metadata job knows its output exactly.
            guard let path = metadata?.outputPath, !path.isEmpty,
                fileManager.fileExists(atPath: path)
            else { return [] }
            return [URL(fileURLWithPath: path)]
        }
        guard let directory = outputDirectory, let startedAt,
            let name = resolvedSaveName ?? options?.basic.saveName
        else { return [] }
        return OutputLocator.files(
            in: directory, namedLike: name, modifiedSince: startedAt, fileManager: fileManager)
    }

    // MARK: - Progress across streams

    /// The stream currently transferring.
    ///
    /// Identified by having a speed at all: the engine prints `-` for a task it has
    /// not started *and* for one that has finished, so at most one stream shows a rate.
    /// Falls back to the first unfinished stream — during the merge phase every rate is
    /// `-` — and then to the last, so a finished job still has something to report.
    var activeStream: EngineOutputParser.Progress? {
        streamProgress.first { !$0.speedText.isEmpty }
            ?? streamProgress.first { $0.percent < 100 }
            ?? streamProgress.last
    }

    /// Overall progress across every stream, 0–100.
    ///
    /// The mean of the per-stream percentages, **not** the summed counts: a stream the
    /// engine has not reached reports `0/100` — Spectre's default `MaxValue`, not a
    /// segment count — so summing would weight a pending subtitle track as heavily as a
    /// hundred-segment video. The mean is also monotonic, which a progress bar needs;
    /// following the active stream instead would send the bar back to zero at every
    /// track boundary.
    var overallPercent: Double? {
        guard !streamProgress.isEmpty else { return nil }

        // A stream the engine announced but has not drawn a bar for yet counts as 0%, so a
        // late row cannot pull the bar backwards.
        let count = max(streamProgress.count, streamEstimates.count)
        let weights = streamWeights(count: count)
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }

        var weighted = 0.0
        for index in 0..<count {
            let percent = index < streamProgress.count ? streamProgress[index].percent : 0
            weighted += weights[index] * percent
        }
        return weighted / total
    }

    /// One weight per stream, in the engine's order. See `StreamEstimate` for the idea.
    ///
    /// Bars are matched to the announced streams by kind and by position within that kind
    /// rather than by overall position, so one missing or reordered line cannot shift every
    /// weight after it. A stream with nothing announced gets a default for its kind.
    private func streamWeights(count: Int) -> [Double] {
        var announced: [StreamEstimate.Kind: [StreamEstimate]] = [:]
        for estimate in streamEstimates { announced[estimate.kind, default: []].append(estimate) }
        let videoFallback = streamEstimates.lazy.filter { $0.kind == .video }
            .compactMap(\.bitrateKbps).max()

        var seen: [StreamEstimate.Kind: Int] = [:]
        return (0..<count).map { index in
            // Past the drawn bars, the remaining announced streams in order.
            guard index < streamProgress.count else {
                let estimate = index < streamEstimates.count ? streamEstimates[index] : nil
                return estimate?.weight(videoFallbackKbps: videoFallback)
                    ?? StreamEstimate.defaultWeight(for: nil)
            }
            let kind = StreamEstimate.kind(ofDescription: streamProgress[index].streamDescription)
            guard let kind else { return StreamEstimate.defaultWeight(for: nil) }
            let occurrence = seen[kind, default: 0]
            seen[kind] = occurrence + 1
            if let list = announced[kind], occurrence < list.count {
                return list[occurrence].weight(videoFallbackKbps: videoFallback)
            }
            return StreamEstimate.defaultWeight(for: kind)
        }
    }

    /// Which stream of how many is being fetched, for a caption like "track 1/3".
    /// `nil` for a single-stream job, where the count adds nothing.
    var activeStreamPosition: (index: Int, count: Int)? {
        guard streamProgress.count > 1, let active = activeStream,
            let index = streamProgress.firstIndex(where: {
                $0.streamDescription == active.streamDescription
            })
        else { return nil }
        return (index + 1, streamProgress.count)
    }

    /// The most recent ERROR or WARN message, trimmed to the human-readable part.
    ///
    /// A fatal engine exception is **not** reliably logged at WARN or ERROR. Because
    /// the engine omits newlines, its `Unhandled exception:` text gets appended to
    /// whatever record was being printed — in a real crash it landed on an INFO line
    /// listing a subtitle track:
    ///
    ///     INFO : Sub subtitles | en | EnglishUnhandled exception: System.ArgumentException…
    ///
    /// A WARN/ERROR-only search then returned the last *ordinary* warning, so the
    /// window reported "Writing meta json" for a crash. Unhandled exceptions are
    /// therefore matched by content at any level, and preferred over level-based
    /// matches since they are the actual cause.
    var lastErrorMessage: String? {
        let records = log.records
        if let fatal = records.last(where: { $0.message.contains(Self.fatalMarker) }) {
            return Self.humanReadablePrefix(of: Self.fromFatalMarker(in: fatal.message))
        }
        // The closing `Failed` verdict is skipped: it is the engine saying *that* the
        // run failed, never *why*, and it is always the last ERROR record — so taking
        // the last one blindly reported "Failed" and buried the real cause
        // (`Segment count check not pass, total: 8, downloaded: 6.`) one line above it.
        return records.last {
            ($0.level == .error || $0.level == .warn) && Self.verdictOnly($0) == nil
                && !FFmpegOutput.isGenericFailure($0.message)
        }
        .map { Self.humanReadablePrefix(of: $0.message) }
    }

    private static func verdictOnly(_ record: EngineOutputParser.LogRecord)
        -> EngineOutputParser.Verdict?
    {
        EngineOutputParser.verdict(in: record)
    }

    // MARK: - Deciding how an engine run ended

    /// How to treat a finished engine run. `nil` means it succeeded.
    ///
    /// A pure function so the rule can be tested without spawning anything, because
    /// the rule is not obvious:
    ///
    /// 🔴 **The engine's own verdict outranks its exit code.** A download that fails
    /// its segment-count check logs `ERROR: Failed` and then **exits 0** — see
    /// `EngineOutputParser.Verdict` for the mechanism — so testing `exitCode == 0`
    /// first reports a broken download as finished, which is exactly what it did.
    ///
    /// A non-zero code is still trusted on its own, because it covers everything the
    /// engine never reaches a verdict for: a parse error, a missing input file, a crash.
    static func engineOutcome(
        verdict: EngineOutputParser.Verdict?,
        exitCode: Int32,
        wasTerminatedBySignal: Bool,
        lastError: String?
    ) -> Failure? {
        // Terminated without the surrounding task being cancelled: never report that as
        // success.
        if wasTerminatedBySignal {
            return .engineExited(code: exitCode, lastError: lastError)
        }
        if verdict == .failed {
            return .engineReportedFailure(lastError: lastError)
        }
        if exitCode != 0 {
            return .engineExited(code: exitCode, lastError: lastError)
        }
        return nil
    }

    /// How the .NET runtime introduces an unhandled exception.
    private static let fatalMarker = "Unhandled exception:"

    /// Drops the unrelated log text an exception was glued onto, keeping the
    /// exception itself.
    private static func fromFatalMarker(in message: String) -> String {
        guard let range = message.range(of: fatalMarker) else { return message }
        return String(message[range.lowerBound...])
    }

    /// Drops everything from the first stack-trace frame onwards.
    static func humanReadablePrefix(of message: String) -> String {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `at Namespace.Type.Method` frames and the separators between them.
            if trimmed.hasPrefix("at ") || trimmed.hasPrefix("--- End of stack trace") {
                break
            }
            kept.append(line)
        }
        let result = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Never return empty: a message consisting only of frames would otherwise
        // leave the UI with nothing to show.
        return result.isEmpty ? message : result
    }
}

// MARK: - Log buffer

/// Fixed-capacity log storage.
///
/// A live recording can run for hours and the engine prints continuously, so an
/// unbounded array would grow without limit. Old records are dropped rather than
/// old *bytes*, keeping whole records intact for display.
nonisolated struct LogBuffer: Sendable {
    /// Roughly a few thousand lines: enough to diagnose a failure, small enough
    /// that memory stays flat on a long run.
    static let capacity = 2000

    private(set) var records: [EngineOutputParser.LogRecord] = []
    /// Number of records discarded, so the UI can say the log was truncated
    /// instead of silently showing a partial history.
    private(set) var droppedCount = 0

    mutating func append(_ record: EngineOutputParser.LogRecord) {
        records.append(record)
        trimIfNeeded()
    }

    mutating func append(contentsOf newRecords: [EngineOutputParser.LogRecord]) {
        guard !newRecords.isEmpty else { return }
        records.append(contentsOf: newRecords)
        trimIfNeeded()
    }

    private mutating func trimIfNeeded() {
        let excess = records.count - Self.capacity
        guard excess > 0 else { return }
        records.removeFirst(excess)
        droppedCount += excess
    }

    var isTruncated: Bool { droppedCount > 0 }

    /// Plain text for copying or saving to a file.
    func plainText() -> String {
        var lines = records.map { "\($0.timestamp) \($0.level.rawValue) : \($0.message)" }
        if isTruncated {
            lines.insert("… \(droppedCount) earlier records dropped …", at: 0)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Metadata pass

/// Options for the ffmpeg pass that writes container metadata and an optional
/// cover image onto a file that already exists.
///
/// Ported from the web generator's Metadata tab, and — like it — a **standalone**
/// operation rather than a step of a download: the app's Metadata tab builds one of
/// these and enqueues it as its own job. Restricted to ffmpeg, because mp4box is
/// neither discovered nor shipped by this app, so offering it would produce
/// commands the app cannot run.
nonisolated struct MetadataOptions: Equatable, Codable, Sendable {
    var inputPath: String = ""
    var outputPath: String = ""
    var coverImagePath: String?
    var title: String?
    var description: String?
    /// Free-form; ffmpeg accepts a range of date formats here.
    var date: String?

    var hasAnyMetadata: Bool {
        [title, description, date].contains { !($0 ?? "").isEmpty } || coverImagePath != nil
    }
}
