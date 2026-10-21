import Foundation
import Observation

/// Owns the job list and drives the engine and ffmpeg.
///
/// `@MainActor` because it is the SwiftUI view model: all state mutation happens on
/// the main actor, while the blocking process work lives in `ProcessRunner` on
/// background queues. That split is why `Core` types are `nonisolated` — they are
/// touched from both sides.
@MainActor
@Observable
final class DownloadCoordinator {

    // MARK: - State

    private(set) var jobs: [DownloadJob] = []

    /// Resolved tool paths, looked up once and surfaced so the UI can explain a
    /// missing tool before the user starts a download and hits it as a failure.
    private(set) var engineStatus: Result<ToolLocator.Resolved, ToolLocator.LocateError>
    private(set) var ffmpegStatus: Result<ToolLocator.Resolved, ToolLocator.LocateError>

    /// How many downloads may run at once. The engine is already internally
    /// parallel (`--thread-count` defaults to the core count), so running several
    /// jobs concurrently oversubscribes the network and the disk; one at a time is
    /// the useful default.
    var maximumConcurrentDownloads = 1

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Jobs started while every slot was busy, in the order they were asked for.
    private var waitingStarts: [UUID] = []

    /// Whether anything is running, stopping or about to — what quitting would interrupt.
    var hasActiveWork: Bool { !runningTasks.isEmpty }

    /// How many jobs are running right now.
    var activeJobCount: Int { runningTasks.count }

    init() {
        engineStatus = ToolLocator.locate(.engine)
        ffmpegStatus = ToolLocator.locate(.ffmpeg)
    }

    /// For tests: a coordinator whose tools are given rather than discovered, so a fake
    /// engine can stand in for the real one without touching the user's defaults.
    init(
        engineStatus: Result<ToolLocator.Resolved, ToolLocator.LocateError>,
        ffmpegStatus: Result<ToolLocator.Resolved, ToolLocator.LocateError>
    ) {
        self.engineStatus = engineStatus
        self.ffmpegStatus = ffmpegStatus
    }

    // MARK: - Tool availability

    var engineURL: URL? { try? engineStatus.get().url }
    var ffmpegURL: URL? { try? ffmpegStatus.get().url }

    /// Re-runs discovery, for after the user installs ffmpeg or picks a path.
    func refreshToolStatus() {
        engineStatus = ToolLocator.locate(.engine)
        ffmpegStatus = ToolLocator.locate(.ffmpeg)
    }

    // MARK: - Job management

    @discardableResult
    func addJob(options: DownloadOptions) -> UUID {
        let job = DownloadJob(options: options)
        jobs.append(job)
        return job.id
    }

    /// Enqueues a standalone ffmpeg metadata pass over a file that already exists.
    ///
    /// A separate kind of job rather than a step of a download: the Metadata tab is
    /// its own tool, so it must work on any file the user points at, including one
    /// this app never downloaded.
    @discardableResult
    func addMetadataJob(metadata: MetadataOptions) -> UUID {
        let job = DownloadJob(metadata: metadata)
        jobs.append(job)
        return job.id
    }

    func removeJob(id: UUID) {
        cancelJob(id: id)
        waitingStarts.removeAll { $0 == id }
        jobs.removeAll { $0.id == id }
    }

    /// Removes finished jobs, leaving anything queued or running untouched.
    func clearFinishedJobs() {
        jobs.removeAll { $0.state.isTerminal }
    }

    private func index(of id: UUID) -> Int? {
        jobs.firstIndex { $0.id == id }
    }

    private func update(_ id: UUID, _ mutate: (inout DownloadJob) -> Void) {
        guard let index = index(of: id) else { return }
        mutate(&jobs[index])
    }

    // MARK: - Starting and stopping

    /// Starts a job, or does nothing if it is already running or finished.
    func startJob(id: UUID) {
        guard let index = index(of: id) else { return }
        guard !jobs[index].state.isRunning, !jobs[index].isStopping else { return }

        // One slot by default: the engine is already parallel inside, so a second
        // simultaneous job only fights the first for network and disk. Rather than refuse,
        // the job waits and starts by itself — a button that silently did nothing would
        // look broken.
        guard runningTasks.count < maximumConcurrentDownloads else {
            if !waitingStarts.contains(id) { waitingStarts.append(id) }
            update(id) { $0.isWaitingForSlot = true }
            return
        }
        waitingStarts.removeAll { $0 == id }
        update(id) { $0.isWaitingForSlot = false }

        let job = jobs[index]

        // No download options means a metadata job: ffmpeg only, no engine run.
        guard let jobOptions = job.options else {
            guard let metadata = job.metadata else {
                finish(id: id, with: .failed(.invalidOptions(["This job has nothing to run."])))
                return
            }
            startMetadataJob(id: id, metadata: metadata)
            return
        }

        // Validate before spawning: the engine would fail on these too, but with a
        // stack trace instead of a message the user can act on.
        let issues = CommandBuilder.validate(jobOptions).map(\.message)
        guard issues.isEmpty else {
            finish(id: id, with: .failed(.invalidOptions(issues)))
            return
        }

        let engine: URL
        switch engineStatus {
        case .success(let resolved): engine = resolved.url
        case .failure(let error):
            finish(
                id: id,
                with: .failed(
                    .toolMissing(
                        [error.errorDescription, error.recoverySuggestion]
                            .compactMap { $0 }
                            .joined(separator: "\n")
                    )
                )
            )
            return
        }

        let options = Self.prepared(jobOptions, ffmpegPath: ffmpegURL?.path)

        // With no selection the engine falls through to an interactive
        // Spectre.Console MultiSelectionPrompt (Program.cs, the final `else` of the
        // selection branch). That prompt needs a terminal; driven as a child process
        // with piped stdout it crashes mid-render:
        //
        //   System.ArgumentException: Offset and length were out of bounds …
        //      at Spectre.Console.MultiSelectionPrompt`1.Show(IAnsiConsole)
        //      at N_m3u8DL_RE.Util.FilterUtil.SelectStreams(…)
        //
        // So the app asks instead: list the tracks with --skip-download, present
        // them, then download the chosen ones. This replaces an earlier workaround
        // that silently forced --auto-select, which downloaded tracks the user never
        // saw.
        guard options.hasExplicitStreamSelection else {
            update(id) { $0.options = options }
            probeStreams(id: id, engine: engine, options: options)
            return
        }

        launchDownload(id: id, engine: engine, options: options)
    }

    /// The options with everything the app must pin for its own parsing to work.
    ///
    /// Each default here exists because the engine's own default breaks something we read:
    ///
    /// - `--ffmpeg-binary-path`: so muxing does not depend on the engine's own search
    ///   finding a different binary — or, under a Finder launch with a minimal `PATH`,
    ///   none at all.
    /// - `--no-ansi-color`: the engine's colour handling is for a terminal; plain text is
    ///   what the parser expects.
    /// - 🔴 `--log-file-path`: left alone, the engine writes `Logs/` **next to its own
    ///   executable**, which here is inside `M3U8Downloader.app/Contents/Resources` — every
    ///   download and every probe added a file to a signed bundle (measured: 16 files in
    ///   `build/engine/osx-arm64/Logs`), and a read-only install turned it into
    ///   `ERROR: Init log failed!`, which `lastErrorMessage` could then report as the cause
    ///   of an unrelated failure. One file under `~/Library/Logs` instead, overwritten per
    ///   run (the engine rewrites an explicit path), so nothing accumulates. Note the
    ///   engine writes its full command line there, headers included. Skipped when the user
    ///   chose `--no-log` or a path of their own.
    /// - 🔴 `--ui-language en-US`: left alone, the engine follows the **system** language,
    ///   and under a Chinese one every message we recognise arrives translated — the phase
    ///   milestones (`Parsing streams`, `Start downloading`, `Muxing`) and `Save Name:`
    ///   all stop matching, silently. Measured: `--ui-language zh-CN` yields
    ///   `内容匹配` / `正在解析媒体信息`. It went unnoticed because the development machine's
    ///   primary language is English.
    ///
    /// A value the user set explicitly is respected in all three cases.
    static func prepared(_ options: DownloadOptions, ffmpegPath: String?) -> DownloadOptions {
        var options = options
        if options.advanced.ffmpegBinaryPath == nil, let ffmpegPath {
            options.advanced.ffmpegBinaryPath = ffmpegPath
        }
        if options.advanced.noAnsiColor == nil {
            options.advanced.noAnsiColor = true
        }
        if options.advanced.uiLanguage == nil {
            options.advanced.uiLanguage = .enUS
        }
        if options.advanced.noLog != true, options.advanced.logFilePath == nil {
            options.advanced.logFilePath = logFileURL?.path
        }
        return options
    }

    /// Where the engine's own log goes: `~/Library/Logs/M3U8Downloader/engine.log`.
    static var logFileURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/M3U8Downloader/engine.log")
    }

    /// The options for the stream-listing run: the user's own, bent so the run can only
    /// ever produce `meta.json` in `directory`.
    ///
    /// Static and pure so the overrides are testable: each one is invisible when it is
    /// missing — the probe just reports "the engine did not write a stream list".
    static func probeOptions(from options: DownloadOptions, directory: URL) -> DownloadOptions {
        var probeOptions = options
        probeOptions.advanced.skipDownload = true
        probeOptions.basic.saveDirectory = directory.path
        // 🔴 Both of these would otherwise make the probe fail while looking like a
        // network or manifest problem. The engine writes `meta.json` under
        // `<tmp-dir>/<save-name>/`, not under the save directory, so a user's `--tmp-dir`
        // sends it somewhere the probe never looks (and leaves files behind there); and it
        // writes the file only when `--write-meta-json` is on. Measured against the
        // engine: with either setting the probe directory stays empty.
        probeOptions.basic.tempDirectory = directory.path
        probeOptions.advanced.writeMetaJSON = true
        // Any non-interactive selection avoids the crashing prompt; the probe only
        // needs meta.json, which the engine writes before selection happens.
        probeOptions.selection.autoSelect = true
        return probeOptions
    }

    /// Runs the engine with `--skip-download` to list tracks, then hands them to the
    /// UI.
    private func probeStreams(id: UUID, engine: URL, options: DownloadOptions) {
        // The probe writes into a temporary directory rather than the user's output
        // folder: it produces a timestamped tree of metadata that would otherwise
        // pile up next to real downloads.
        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-probe-\(id.uuidString)")

        let probeOptions = Self.probeOptions(from: options, directory: probeDirectory)

        let argv = CommandBuilder.arguments(for: probeOptions)
        update(id) {
            $0.state = .running(.probingStreams)
            $0.startedAt = Date()
            $0.finishedAt = nil
            $0.streamProgress = []
            $0.engineVerdict = nil
            $0.resolvedSaveName = nil
            $0.resetStreamEstimates()
            $0.log = LogBuffer()
            $0.executedCommand = CommandBuilder.shellCommand(
                executable: engine.path, arguments: argv)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            // One exit path for every `return` below. The two early ones used to skip the
            // bookkeeping, which was merely untidy until the slot limit existed: a job
            // that stays registered holds the only slot, and nothing else can ever start.
            defer {
                try? FileManager.default.removeItem(at: probeDirectory)
                self.runningTasks[id] = nil
                self.startNextWaiting()
            }
            try? FileManager.default.createDirectory(
                at: probeDirectory, withIntermediateDirectories: true)

            let buffer = OutputBuffer()
            do {
                let result = try await ProcessRunner(
                    executable: engine,
                    arguments: argv,
                    workingDirectory: probeDirectory
                ).run { chunk in buffer.append(chunk.text) }

                if let text = buffer.take() { self.ingest(text, into: id) }

                if Task.isCancelled {
                    self.finish(id: id, with: .cancelled)
                    return
                }
                if let failure = self.outcome(of: id, result) {
                    self.finish(id: id, with: .failed(failure))
                    return
                }
                let catalog = try StreamCatalog.loadMetaJSON(in: probeDirectory)
                self.update(id) { $0.state = .awaitingStreamSelection(catalog) }
            } catch {
                if let text = buffer.take() { self.ingest(text, into: id) }
                self.finish(
                    id: id, with: .failed(.streamProbeFailed(error.localizedDescription)))
            }
        }
        runningTasks[id] = task
    }

    /// Applies the user's track choice and starts the real download.
    func confirmStreamSelection(id: UUID, selection: Set<String>) {
        guard let index = index(of: id),
            case .awaitingStreamSelection(let catalog) = jobs[index].state,
            var options = jobs[index].options
        else { return }

        var unexpressible: [String] = []
        for filter in catalog.filters(for: selection) {
            switch filter {
            case .exact(let flag, let value):
                switch flag {
                case "-sv": options.selection.selectVideo = value
                case "-sa": options.selection.selectAudio = value
                case "-ss": options.selection.selectSubtitle = value
                default: break
                }
            case .inexpressible(let kind, _):
                unexpressible.append(
                    "The chosen \(kind.rawValue) tracks cannot be requested precisely.")
            }
        }
        guard unexpressible.isEmpty else {
            finish(id: id, with: .failed(.invalidOptions(unexpressible)))
            return
        }

        guard let engine = engineURL else { return }
        update(id) { $0.options = options }
        guard runningTasks.count < maximumConcurrentDownloads else {
            // The choice is saved in the options; `startJob` goes straight to the download
            // once a slot frees, because a selection is now explicit.
            update(id) {
                $0.state = .queued
                $0.isWaitingForSlot = true
            }
            if !waitingStarts.contains(id) { waitingStarts.append(id) }
            return
        }
        launchDownload(id: id, engine: engine, options: options)
    }

    /// Abandons a job that was waiting for a track choice.
    func cancelStreamSelection(id: UUID) {
        guard let index = index(of: id), jobs[index].state.needsUserDecision else { return }
        finish(id: id, with: .cancelled)
    }

    private func launchDownload(id: UUID, engine: URL, options: DownloadOptions) {
        // The engine creates its save directory, but the process is *started in* it, and
        // `Process` reports a missing working directory as "The file “X” doesn’t exist" —
        // which `RunError` then wrapped as "Could not start N_m3u8DL-RE", blaming the engine
        // for an unmounted drive or a mistyped folder. Make it, or say what is wrong.
        if let directory = OutputLocator.directory(saveDirectory: options.basic.saveDirectory) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                update(id) { $0.options = options }
                finish(
                    id: id,
                    with: .failed(
                        .invalidOptions([
                            "The save folder “\(directory.path)” cannot be used: "
                                + error.localizedDescription
                        ])))
                return
            }
        }
        let argv = CommandBuilder.arguments(for: options)
        update(id) {
            $0.options = options
            $0.state = .running(.starting)
            $0.startedAt = Date()
            $0.finishedAt = nil
            $0.streamProgress = []
            $0.engineVerdict = nil
            $0.resolvedSaveName = nil
            $0.resetStreamEstimates()
            $0.log = LogBuffer()
            $0.executedCommand = CommandBuilder.shellCommand(
                executable: engine.path, arguments: argv)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, engine: engine, arguments: argv)
        }
        runningTasks[id] = task
    }

    /// Stops a job: the process and everything it started.
    ///
    /// The task stays registered until the process is really gone, which is what keeps the
    /// slot busy meanwhile. Dropping it at once (as this used to) let the next job start
    /// alongside a process that was still shutting down, and left the row looking idle
    /// while files were still being written.
    func cancelJob(id: UUID) {
        if waitingStarts.contains(id) {
            waitingStarts.removeAll { $0 == id }
            update(id) { $0.isWaitingForSlot = false }
        }
        guard let task = runningTasks[id] else { return }
        update(id) { $0.isStopping = true }
        task.cancel()
    }

    func cancelAll() {
        waitingStarts.removeAll()
        for id in Array(runningTasks.keys) { cancelJob(id: id) }
    }

    /// Stops everything and waits until the processes are gone, or `timeout` passes.
    ///
    /// For quitting: exiting while the engine runs would leave it, and any ffmpeg it
    /// started, writing files that nothing reports on. The timeout only bounds the wait;
    /// the runner kills what ignores SIGTERM after its own grace period, which is shorter.
    func stopAllAndWait(timeout: Duration = .seconds(10)) async {
        let tasks = Array(runningTasks.values)
        cancelAll()
        guard !tasks.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for task in tasks { await task.value }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Starts jobs that were waiting for a slot, as many as now fit.
    private func startNextWaiting() {
        while runningTasks.count < maximumConcurrentDownloads, !waitingStarts.isEmpty {
            let next = waitingStarts.removeFirst()
            guard index(of: next) != nil else { continue }
            startJob(id: next)
        }
    }

    // MARK: - Execution

    private func run(id: UUID, engine: URL, arguments: [String]) async {
        let runner = ProcessRunner(
            executable: engine,
            arguments: arguments,
            workingDirectory: workingDirectory(for: id)
        )

        // Output arrives on background threads. It is buffered here and drained on
        // the main actor rather than dispatched per chunk.
        //
        // An earlier version did `Task { @MainActor in self.ingest(…) }` inside the
        // callback. Those tasks are only *scheduled*, so when a run finishes quickly
        // — `--skip-download` completes in ~0.05s — the job reached a terminal state
        // before any of them executed and the log came out **empty** while the state
        // said succeeded. Measured: 11 records via ProcessRunner directly, 0 through
        // the coordinator.
        let buffer = OutputBuffer()
        let handle: @Sendable (ProcessRunner.Chunk) -> Void = { chunk in
            buffer.append(chunk.text)
        }

        // Drain periodically so the UI updates during a long download instead of
        // only at the end.
        //
        // The pipe is read in arbitrary pieces, so a record can arrive split in two; the
        // assembler holds the unfinished end back. Shared between the pump and the final
        // drain, hence the reference box (both only ever run on the main actor).
        let assembler = AssemblerBox()
        let pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                if let ready = assembler.value.feed(buffer.take()) {
                    self.ingest(ready, into: id)
                }
            }
        }

        do {
            let result = try await runner.run(onOutput: handle)
            pump.cancel()
            // Final drain, on the main actor, before any state decision is made:
            // failure reporting reads the log for the engine's own error text.
            if let remaining = assembler.value.finish(buffer.take()) {
                ingest(remaining, into: id)
            }

            if Task.isCancelled {
                finish(id: id, with: .cancelled)
            } else if let failure = outcome(of: id, result) {
                finish(id: id, with: .failed(failure))
            } else {
                finish(id: id, with: .succeeded)
            }
        } catch {
            // Without this the pump keeps waking eight times a second for a job that
            // never started.
            pump.cancel()
            finish(id: id, with: .failed(.launchFailed(error.localizedDescription)))
        }
        runningTasks[id] = nil
        startNextWaiting()
    }

    /// Validates a metadata job and launches ffmpeg for it.
    ///
    /// Unlike a download, the command is recorded here rather than after resolving
    /// the engine: for a metadata job this ffmpeg invocation *is* the job, so the
    /// Command tab must show it.
    private func startMetadataJob(id: UUID, metadata: MetadataOptions) {
        let issues = MetadataCommandBuilder.validate(metadata).map(\.message)
        guard issues.isEmpty else {
            finish(id: id, with: .failed(.invalidOptions(issues)))
            return
        }
        guard let ffmpeg = ffmpegURL else {
            let error = ffmpegStatus.failureError
            finish(
                id: id,
                with: .failed(
                    .toolMissing(
                        [error?.errorDescription, error?.recoverySuggestion]
                            .compactMap { $0 }
                            .joined(separator: "\n")
                    )
                )
            )
            return
        }

        let argv = MetadataCommandBuilder.arguments(for: metadata)
        // Only a file this run creates may be deleted if it fails: one that was already
        // there belongs to the user, and ffmpeg's refusal to overwrite it is the right outcome.
        let partialOutput: URL? =
            FileManager.default.fileExists(atPath: metadata.outputPath)
            ? nil : URL(fileURLWithPath: metadata.outputPath)
        update(id) {
            $0.state = .running(.applyingMetadata)
            $0.startedAt = Date()
            $0.finishedAt = nil
            $0.streamProgress = []
            $0.engineVerdict = nil
            $0.resolvedSaveName = nil
            $0.resetStreamEstimates()
            $0.log = LogBuffer()
            $0.executedCommand = CommandBuilder.shellCommand(
                executable: ffmpeg.path, arguments: argv)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runMetadata(
                id: id, ffmpeg: ffmpeg, arguments: argv, partialOutput: partialOutput)
        }
        runningTasks[id] = task
    }

    private func runMetadata(
        id: UUID, ffmpeg: URL, arguments: [String], partialOutput: URL?
    ) async {
        let runner = ProcessRunner(executable: ffmpeg, arguments: arguments)
        // Same buffering as the engine run: a dispatched-per-chunk callback loses
        // output when the process finishes quickly.
        let buffer = OutputBuffer()
        let handle: @Sendable (ProcessRunner.Chunk) -> Void = { chunk in
            buffer.append(chunk.text)
        }

        do {
            let result = try await runner.run(onOutput: handle)
            if let remaining = buffer.take() { ingestPlainText(remaining, into: id) }
            if Task.isCancelled {
                discardPartialOutput(partialOutput)
                finish(id: id, with: .cancelled)
            } else if result.isSuccess {
                finish(id: id, with: .succeeded)
            } else {
                discardPartialOutput(partialOutput)
                finish(
                    id: id,
                    with: .failed(
                        .metadataFailed(code: result.exitCode, lastError: lastError(of: id))))
            }
        } catch {
            discardPartialOutput(partialOutput)
            finish(id: id, with: .failed(.launchFailed(error.localizedDescription)))
        }
        runningTasks[id] = nil
        startNextWaiting()
    }

    /// Removes what a failed or stopped ffmpeg run left behind.
    ///
    /// ffmpeg creates the output before it has anything to put in it, so a failure leaves a
    /// zero-byte or truncated file — and without `-y` ffmpeg then refuses to overwrite it,
    /// so **every retry failed** with "already exists" until the user deleted it by hand
    /// (measured). It also let "Show in Finder" offer the broken file as the result.
    private func discardPartialOutput(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Output handling

    /// Parses engine output and folds it into the job's state.
    private func ingest(_ text: String, into id: UUID) {
        guard index(of: id) != nil else { return }

        for event in EngineOutputParser.events(in: text) {
            switch event {
            case .progress(let progress):
                update(id) {
                    // Folded in per stream: one repaint carries a row for every
                    // selected track, so overwriting a single field would leave
                    // whichever row printed last on display.
                    $0.record(progress)
                    // Seeing progress means downloading has begun, even if the
                    // milestone line was missed.
                    if case .running(let phase) = $0.state, phase != .downloading {
                        $0.state = .running(.downloading)
                    }
                }
            case .log(let record):
                update(id) {
                    $0.log.append(record)
                    // The engine's own verdict is the only trustworthy success signal;
                    // its exit code is 0 even for a failed download.
                    if let verdict = EngineOutputParser.verdict(in: record) {
                        $0.engineVerdict = verdict
                    }
                    if let name = EngineOutputParser.saveName(in: record) {
                        $0.resolvedSaveName = name
                    }
                    $0.noteSelection(record)
                }
                if let milestone = EngineOutputParser.Milestone.detect(in: record.message) {
                    apply(milestone, to: id)
                }
            }
        }
    }

    /// ffmpeg does not use the engine's log format, so its output is stored as-is
    /// rather than run through the engine parser.
    private func ingestPlainText(_ text: String, into id: UUID) {
        let lines =
            text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && !EngineOutputParser.isToolNoise($0) }
        guard !lines.isEmpty else { return }

        let stamp = Self.timeFormatter.string(from: Date())
        update(id) {
            for line in lines {
                $0.log.append(
                    EngineOutputParser.LogRecord(
                        timestamp: stamp, level: FFmpegOutput.level(for: line), message: line)
                )
            }
        }
    }

    private func apply(_ milestone: EngineOutputParser.Milestone, to id: UUID) {
        update(id) { job in
            guard job.state.isRunning else { return }
            switch milestone {
            case .parsingStreams: job.state = .running(.parsing)
            case .startedDownloading: job.state = .running(.downloading)
            case .muxing: job.state = .running(.muxing)
            case .done: break  // The exit code decides success, not this line.
            }
        }
    }

    /// How a finished engine run ended, per `DownloadJob.engineOutcome`. `nil` means it
    /// succeeded.
    private func outcome(of id: UUID, _ result: ProcessRunner.Result) -> DownloadJob.Failure? {
        DownloadJob.engineOutcome(
            verdict: index(of: id).map { jobs[$0].engineVerdict } ?? nil,
            exitCode: result.exitCode,
            wasTerminatedBySignal: result.wasTerminatedBySignal,
            lastError: lastError(of: id)
        )
    }

    private func lastError(of id: UUID) -> String? {
        guard let index = index(of: id) else { return nil }
        return jobs[index].lastErrorMessage
    }

    private func finish(id: UUID, with state: DownloadJob.State) {
        update(id) {
            $0.state = state
            $0.finishedAt = Date()
            $0.isStopping = false
            $0.isWaitingForSlot = false
        }
    }

    /// Where the engine writes when `--save-dir` was not set. Falling back to the
    /// process's current directory would put files somewhere arbitrary for a
    /// Finder-launched app, so Downloads is used instead.
    private func workingDirectory(for id: UUID) -> URL? {
        guard let index = index(of: id) else { return nil }
        return jobs[index].outputDirectory
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// A mutable `ChunkAssembler` shared by two closures on the main actor.
@MainActor
private final class AssemblerBox {
    var value = ChunkAssembler()
}

// MARK: - Output buffering

/// Collects process output written from background threads for the main actor to
/// drain.
///
/// Exists because dispatching a `Task { @MainActor … }` per chunk only *schedules*
/// the work: a process that exits quickly reaches a terminal state before those
/// tasks run, and its output is lost. Buffering makes the handoff explicit, so the
/// final drain can be ordered before any state decision.
///
/// `nonisolated` because this file's target defaults to MainActor isolation while
/// `append` is called from the background queues that drain the pipes.
private nonisolated final class OutputBuffer: @unchecked Sendable {
    private var pending = ""
    private let lock = NSLock()

    func append(_ text: String) {
        lock.lock()
        pending += text
        lock.unlock()
    }

    /// Returns and clears everything buffered so far, or `nil` when empty.
    func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let text = pending
        pending = ""
        return text
    }
}

// MARK: - Helpers

extension Result {
    /// The error, when this is a failure. Reads better than a `switch` at call
    /// sites that only care about the failure case.
    fileprivate var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
