import Foundation
import Testing

@testable import M3U8Downloader

/// Tests for the ffmpeg metadata pass arguments.
///
/// ffmpeg is order-sensitive, so these assert on argument *sequence*, not just
/// presence: a `-map` that precedes its `-i` refers to an input that does not
/// exist yet and ffmpeg rejects it.
struct MetadataCommandBuilderTests {

    @Test("Nothing is produced without an input")
    func emptyWithoutInput() {
        #expect(MetadataCommandBuilder.arguments(for: MetadataOptions()).isEmpty)
    }

    @Test("A plain remux copies every stream")
    func plainRemuxCopiesAllStreams() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/in.mp4"
        options.outputPath = "/tmp/out.mp4"

        // `-map 0` rather than ffmpeg's default selection, which keeps only one
        // stream per type and would silently drop extra audio tracks and subtitles.
        #expect(
            MetadataCommandBuilder.arguments(for: options) == [
                "-i", "/tmp/in.mp4",
                "-map", "0",
                "-c", "copy",
                "/tmp/out.mp4",
            ]
        )
    }

    @Test("Metadata fields are emitted as key=value pairs")
    func metadataFields() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/in.mp4"
        options.outputPath = "/tmp/out.mp4"
        options.title = "My Show"
        options.description = "Episode 1"
        options.date = "2026-01-01"

        let argv = MetadataCommandBuilder.arguments(for: options)
        #expect(argv.contains("title=My Show"))
        #expect(argv.contains("description=Episode 1"))
        #expect(argv.contains("date=2026-01-01"))
        #expect(argv.filter { $0 == "-metadata" }.count == 3)
    }

    @Test("Empty metadata fields are omitted rather than emitted blank")
    func emptyMetadataOmitted() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/in.mp4"
        options.outputPath = "/tmp/out.mp4"
        options.title = ""
        options.description = nil

        #expect(!MetadataCommandBuilder.arguments(for: options).contains("-metadata"))
    }

    @Test("A cover image becomes a second input flagged as attached artwork")
    func coverImageIsAttached() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/in.mp4"
        options.outputPath = "/tmp/out.mp4"
        options.coverImagePath = "/tmp/cover.jpg"

        #expect(
            MetadataCommandBuilder.arguments(for: options) == [
                "-i", "/tmp/in.mp4",
                "-i", "/tmp/cover.jpg",
                "-map", "0",
                "-map", "1:v",
                "-c", "copy",
                "-c:v:1", "mjpeg",
                "-disposition:v:1", "attached_pic",
                "/tmp/out.mp4",
            ]
        )
    }

    @Test(
        "The cover codec follows the file extension",
        arguments: [
            ("/tmp/a.jpg", "mjpeg"),
            ("/tmp/a.jpeg", "mjpeg"),
            ("/tmp/a.JPG", "mjpeg"),
            ("/tmp/a.png", "png"),
            ("/tmp/a.webp", "png"),
            ("/tmp/a", "png"),
        ]
    )
    func coverCodecSelection(path: String, expected: String) {
        #expect(MetadataCommandBuilder.coverCodec(forPath: path) == expected)
    }

    @Test("Inputs precede the maps that refer to them")
    func inputsPrecedeMaps() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/in.mp4"
        options.outputPath = "/tmp/out.mp4"
        options.coverImagePath = "/tmp/cover.png"

        let argv = MetadataCommandBuilder.arguments(for: options)
        let lastInput = argv.lastIndex(of: "-i")
        let firstMap = argv.firstIndex(of: "-map")
        #expect(lastInput != nil && firstMap != nil)
        if let lastInput, let firstMap {
            #expect(lastInput < firstMap, "a -map appears before its -i input")
        }
    }

    @Test("The output path is last")
    func outputIsLast() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/in.mp4"
        options.outputPath = "/tmp/out.mkv"
        options.title = "T"

        #expect(MetadataCommandBuilder.arguments(for: options).last == "/tmp/out.mkv")
    }

    @Test("Paths needing quotes in a shell are passed through untouched")
    func pathsAreNotQuoted() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/My Show $1/ep.mp4"
        options.outputPath = "/tmp/out.mp4"
        options.title = "It's \"quoted\" & $HOME"

        let argv = MetadataCommandBuilder.arguments(for: options)
        // These go straight to Process, so no escaping should be applied. Escaping
        // here would corrupt the actual filename.
        #expect(argv.contains("/tmp/My Show $1/ep.mp4"))
        #expect(argv.contains("title=It's \"quoted\" & $HOME"))
    }

    // MARK: - Suggested output

    @Test("A suggested output path never equals the input")
    func suggestedOutputDiffers() {
        let input = "/tmp/video.mp4"
        let suggested = MetadataCommandBuilder.suggestedOutputPath(forInput: input)
        #expect(suggested == "/tmp/video_meta.mp4")
        #expect(suggested != input)
    }

    @Test("A suggested output handles a missing extension")
    func suggestedOutputWithoutExtension() {
        #expect(
            MetadataCommandBuilder.suggestedOutputPath(forInput: "/tmp/video")
                == "/tmp/video_meta"
        )
    }

    @Test("An empty input suggests nothing")
    func suggestedOutputEmpty() {
        #expect(MetadataCommandBuilder.suggestedOutputPath(forInput: "").isEmpty)
    }

    // MARK: - Validation

    @Test("Missing paths are reported")
    func missingPathsReported() {
        let issues = MetadataCommandBuilder.validate(MetadataOptions())
        #expect(issues.contains { $0.field == .input })
        #expect(issues.contains { $0.field == .output })
    }

    @Test("Writing to the input file is refused")
    func inPlaceRewriteRefused() {
        // ffmpeg truncates the output as it opens it, so an in-place run destroys
        // the source before reading it. This must be caught before launching.
        var options = MetadataOptions()
        options.inputPath = "/tmp/same.mp4"
        options.outputPath = "/tmp/same.mp4"

        #expect(
            MetadataCommandBuilder.validate(options).contains { $0.field == .sameInputAndOutput }
        )
    }

    @Test("The same file reached by a different path spelling is still refused")
    func inPlaceRewriteViaDifferentSpelling() {
        // A user editing the output field by hand can easily produce a path that
        // looks different but resolves to the same file.
        var options = MetadataOptions()
        options.inputPath = "/tmp/dir/../same.mp4"
        options.outputPath = "/tmp/same.mp4"

        #expect(
            MetadataCommandBuilder.validate(options).contains { $0.field == .sameInputAndOutput },
            "an unnormalised path bypassed the in-place check"
        )
    }

    @Test("Distinct paths pass validation")
    func distinctPathsPass() {
        var options = MetadataOptions()
        options.inputPath = "/tmp/in.mp4"
        options.outputPath = "/tmp/out.mp4"

        #expect(MetadataCommandBuilder.validate(options).isEmpty)
    }
}

/// Tests for the bounded log storage.
struct LogBufferTests {

    private func record(_ message: String) -> EngineOutputParser.LogRecord {
        EngineOutputParser.LogRecord(timestamp: "10:00:00.000", level: .info, message: message)
    }

    @Test("Records are kept in order")
    func keepsOrder() {
        var buffer = LogBuffer()
        buffer.append(record("first"))
        buffer.append(record("second"))

        #expect(buffer.records.map(\.message) == ["first", "second"])
        #expect(!buffer.isTruncated)
    }

    @Test("The buffer is capped, dropping the oldest records")
    func capacityIsEnforced() {
        // A live recording prints continuously for hours, so an unbounded buffer is
        // a slow leak. Overfill deliberately and check the cap holds.
        var buffer = LogBuffer()
        let overflow = LogBuffer.capacity + 500
        for index in 0..<overflow {
            buffer.append(record("line \(index)"))
        }

        #expect(buffer.records.count == LogBuffer.capacity)
        #expect(buffer.droppedCount == 500)
        #expect(buffer.isTruncated)
        // The newest records are what matter for diagnosing a failure.
        #expect(buffer.records.last?.message == "line \(overflow - 1)")
        #expect(buffer.records.first?.message == "line 500")
    }

    @Test("A bulk append is capped too")
    func bulkAppendIsCapped() {
        var buffer = LogBuffer()
        let records = (0..<(LogBuffer.capacity + 10)).map { record("line \($0)") }
        buffer.append(contentsOf: records)

        #expect(buffer.records.count == LogBuffer.capacity)
        #expect(buffer.droppedCount == 10)
    }

    @Test("An empty bulk append changes nothing")
    func emptyBulkAppend() {
        var buffer = LogBuffer()
        buffer.append(contentsOf: [])
        #expect(buffer.records.isEmpty)
        #expect(!buffer.isTruncated)
    }

    @Test("Plain text says when records were dropped")
    func plainTextNotesTruncation() {
        var buffer = LogBuffer()
        for index in 0..<(LogBuffer.capacity + 1) {
            buffer.append(record("line \(index)"))
        }

        let text = buffer.plainText()
        // Silently showing a partial history would mislead someone reading a log to
        // diagnose a failure.
        #expect(text.contains("1 earlier records dropped"))
    }

    @Test("Plain text includes level and timestamp")
    func plainTextFormat() {
        var buffer = LogBuffer()
        buffer.append(
            EngineOutputParser.LogRecord(
                timestamp: "10:24:55.718", level: .warn, message: "Writing meta json"))

        #expect(buffer.plainText() == "10:24:55.718 WARN : Writing meta json")
    }
}

/// Tests for job state derivation.
struct DownloadJobTests {

    @Test("The display name prefers the save name")
    func displayNamePrefersSaveName() {
        var options = DownloadOptions()
        options.input = "https://example.com/a/b/stream.m3u8"
        options.basic.saveName = "Episode 1"

        #expect(DownloadJob(options: options).displayName == "Episode 1")
    }

    @Test("The display name falls back to the input's last path component")
    func displayNameFallsBack() {
        var options = DownloadOptions()
        options.input = "https://example.com/a/b/stream.m3u8"

        #expect(DownloadJob(options: options).displayName == "stream.m3u8")
    }

    @Test("A job is never nameless")
    func displayNameNeverEmpty() {
        var options = DownloadOptions()
        options.input = "not-a-url"
        #expect(!DownloadJob(options: options).displayName.isEmpty)
    }

    // MARK: - Metadata jobs

    @Test("A metadata job carries no download options")
    func metadataJobHasNoDownload() {
        // The absence of options is what makes it a metadata job — there is no
        // separate flag that could disagree with it. `DownloadCoordinator.startJob`
        // branches on exactly this.
        var metadata = MetadataOptions()
        metadata.inputPath = "/tmp/in.mp4"
        metadata.outputPath = "/tmp/out.mp4"

        let job = DownloadJob(metadata: metadata)
        #expect(job.options == nil)
        #expect(job.kind == .metadata)
        #expect(job.metadata == metadata)
    }

    @Test("A job with download options is a download")
    func downloadJobKind() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"

        let job = DownloadJob(options: options)
        #expect(job.kind == .download)
        #expect(job.metadata == nil)
    }

    @Test("A metadata job is named after the file it produces")
    func metadataJobNamedAfterOutput() {
        // The output is the artefact the user is waiting for; the input is a file
        // they already have.
        var metadata = MetadataOptions()
        metadata.inputPath = "/Users/me/Movies/episode-1.mp4"
        metadata.outputPath = "/Users/me/Movies/episode-1_meta.mp4"

        #expect(DownloadJob(metadata: metadata).displayName == "episode-1_meta.mp4")
    }

    @Test("A metadata job with no output yet falls back to the input")
    func metadataJobFallsBackToInput() {
        var metadata = MetadataOptions()
        metadata.inputPath = "/Users/me/Movies/episode-1.mp4"

        #expect(DownloadJob(metadata: metadata).displayName == "episode-1.mp4")
    }

    @Test("A metadata job with no paths at all is still named")
    func metadataJobWithoutPathsIsNamed() {
        // `URL(fileURLWithPath: "")` resolves against the current directory, so an
        // unguarded lastPathComponent would name the job after whatever directory
        // the app happens to be running in.
        let name = DownloadJob(metadata: MetadataOptions()).displayName
        #expect(name == "Metadata", "got \(name)")
    }

    @Test("Terminal states are identified")
    func terminalStates() {
        #expect(DownloadJob.State.succeeded.isTerminal)
        #expect(DownloadJob.State.cancelled.isTerminal)
        #expect(DownloadJob.State.failed(.toolMissing("x")).isTerminal)
        #expect(!DownloadJob.State.queued.isTerminal)
        #expect(!DownloadJob.State.running(.downloading).isTerminal)
    }

    @Test("Running states are identified regardless of phase")
    func runningStates() {
        #expect(DownloadJob.State.running(.starting).isRunning)
        #expect(DownloadJob.State.running(.muxing).isRunning)
        #expect(!DownloadJob.State.queued.isRunning)
        #expect(!DownloadJob.State.succeeded.isRunning)
    }

    @Test("A failure prefers the engine's own error text over a bare exit code")
    func failureMessagePrefersEngineText() {
        let withText = DownloadJob.Failure.engineExited(
            code: 1, lastError: "Download first segment failed!")
        #expect(withText.message == "Download first segment failed!")

        let withoutText = DownloadJob.Failure.engineExited(code: 1, lastError: nil)
        #expect(withoutText.message.contains("1"))
    }

    @Test("An empty error string does not produce an empty message")
    func failureMessageHandlesEmptyText() {
        let failure = DownloadJob.Failure.engineExited(code: 7, lastError: "")
        #expect(!failure.message.isEmpty)
        #expect(failure.message.contains("7"))
    }

    @Test("The last error is taken from ERROR and WARN records")
    func lastErrorMessage() {
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(
            EngineOutputParser.LogRecord(timestamp: "1", level: .info, message: "starting"))
        job.log.append(
            EngineOutputParser.LogRecord(timestamp: "2", level: .warn, message: "a warning"))
        job.log.append(
            EngineOutputParser.LogRecord(timestamp: "3", level: .info, message: "more info"))

        // The engine reports most real problems at WARN, including the proxy and
        // segment failures seen in real runs, so WARN counts here.
        #expect(job.lastErrorMessage == "a warning")
    }

    @Test("No error records means no error message")
    func noErrorMessage() {
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(EngineOutputParser.LogRecord(timestamp: "1", level: .info, message: "ok"))
        #expect(job.lastErrorMessage == nil)
    }

    // MARK: - Stack-trace trimming

    @Test("A .NET stack trace is trimmed from the user-facing message")
    func stackTraceIsTrimmed() {
        // Verbatim shape from a real failing run: the engine appends a dozen frames
        // to its fatal errors, which pushed the actual cause out of view in the
        // window while adding nothing a user can act on.
        let raw = """
            nodename nor servname provided, or not known (example.invalid:443)Unhandled exception: System.Exception: Download first segment failed!
               at N_m3u8DL_RE.DownloadManager.SimpleDownloadManager.<DownloadStreamAsync>d__8.MoveNext() + 0x4778
            --- End of stack trace from previous location ---
               at Spectre.Console.Progress.<StartAsync>d__36.MoveNext() + 0x6c
            """

        let trimmed = DownloadJob.humanReadablePrefix(of: raw)

        #expect(trimmed.contains("nodename nor servname provided"))
        #expect(!trimmed.contains("   at "), "stack frames survived")
        #expect(!trimmed.contains("Spectre.Console"), "framework noise survived")
        #expect(!trimmed.contains("End of stack trace"))
        #expect(trimmed.split(separator: "\n").count == 1)
    }

    @Test("A message with no stack trace is left alone")
    func messageWithoutStackTraceIsUnchanged() {
        let plain = "Download first segment failed!"
        #expect(DownloadJob.humanReadablePrefix(of: plain) == plain)
    }

    @Test("A message that is only frames still yields something to show")
    func framesOnlyMessageIsNotEmptied() {
        // Trimming everything would leave the UI with a blank error, which is worse
        // than showing the frames.
        let framesOnly = "   at Foo.Bar() + 0x1\n   at Baz.Qux() + 0x2"
        let trimmed = DownloadJob.humanReadablePrefix(of: framesOnly)
        #expect(!trimmed.isEmpty)
    }

    // MARK: - Fatal exceptions glued onto an INFO record

    @Test("A fatal exception on an INFO record is still reported as the failure")
    func fatalExceptionOnInfoRecordIsFound() throws {
        // Verbatim from a real crash. The engine omits newlines, so its
        // "Unhandled exception:" text landed on an INFO line listing a subtitle
        // track. A WARN/ERROR-only search returned the last ordinary warning, so
        // the window said "Writing meta json" for a crash in the interactive
        // stream-selection prompt.
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(
            .init(
                timestamp: "1", level: .warn, message: "Master List detected, try parse all streams"
            ))
        job.log.append(.init(timestamp: "2", level: .warn, message: "Writing meta json"))
        job.log.append(
            .init(
                timestamp: "3", level: .info,
                message: """
                    Sub subtitles | en | EnglishUnhandled exception: System.ArgumentException: Offset and length were out of bounds for the array.
                       at Spectre.Console.MultiSelectionPrompt`1.Show(IAnsiConsole) + 0x5c
                    """
            )
        )

        let message = try #require(job.lastErrorMessage)
        #expect(message.contains("ArgumentException"), "the real cause is missing")
        #expect(
            message != "Writing meta json", "reported an unrelated warning instead of the crash")
        // The log text the exception was glued onto is not part of the cause.
        #expect(!message.contains("Sub subtitles"))
        #expect(!message.contains("   at "))
    }

    @Test("An ordinary warning is still used when nothing crashed")
    func ordinaryWarningStillReported() {
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(.init(timestamp: "1", level: .info, message: "starting"))
        job.log.append(.init(timestamp: "2", level: .warn, message: "something odd"))

        #expect(job.lastErrorMessage == "something odd")
    }

    @Test("A crash is preferred over a later ordinary warning")
    func crashWinsOverLaterWarning() {
        // Ordering matters: the engine keeps logging after the exception is printed,
        // so a level-based search would find a warning that came afterwards.
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(
            .init(
                timestamp: "1", level: .info,
                message: "x Unhandled exception: System.Exception: boom"))
        job.log.append(.init(timestamp: "2", level: .warn, message: "later noise"))

        #expect(job.lastErrorMessage?.contains("boom") == true)
    }

    @Test("The trimmed message is what a failure reports")
    func failureUsesTrimmedMessage() throws {
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(
            EngineOutputParser.LogRecord(
                timestamp: "1",
                level: .warn,
                message: "real cause here\n   at Some.Frame() + 0x1"
            )
        )

        let message = try #require(job.lastErrorMessage)
        #expect(message == "real cause here")
        // The full text must remain in the log for diagnosis.
        #expect(job.log.plainText().contains("at Some.Frame()"))
    }
}

/// Tests for the coordinator's metadata-job branch.
///
/// `@MainActor` because `DownloadCoordinator` is the SwiftUI view model. These stay
/// deliberately on the paths that reject a job *before* anything is spawned: a job
/// whose paths merely point at files that do not exist would launch a real ffmpeg.
@MainActor
struct MetadataJobCoordinationTests {

    @Test("A metadata job is queued without any download options")
    func queuedAsMetadataJob() throws {
        let coordinator = DownloadCoordinator()

        var metadata = MetadataOptions()
        metadata.inputPath = "/tmp/in.mp4"
        metadata.outputPath = "/tmp/out.mp4"
        let id = coordinator.addMetadataJob(metadata: metadata)

        let job = try #require(coordinator.jobs.first { $0.id == id })
        #expect(job.kind == .metadata)
        #expect(job.options == nil)
        #expect(job.state == .queued)
    }

    @Test("Starting a metadata job with no files reports the problem instead of running ffmpeg")
    func invalidMetadataJobIsRejected() throws {
        // The empty-paths case matters because it is what a freshly restored session
        // looks like: `OptionsPersistence` deliberately stores the descriptive fields
        // and clears the paths.
        let coordinator = DownloadCoordinator()
        let id = coordinator.addMetadataJob(metadata: MetadataOptions())
        coordinator.startJob(id: id)

        let job = try #require(coordinator.jobs.first { $0.id == id })
        guard case .failed(.invalidOptions(let issues)) = job.state else {
            Issue.record("expected invalidOptions, got \(job.state)")
            return
        }
        #expect(issues.contains("An input file is required."))
        #expect(issues.contains("An output file is required."))
        // Not running: nothing was spawned.
        #expect(!job.state.isRunning)
    }

    @Test("A metadata job never takes the download path")
    func metadataJobDoesNotProbeStreams() throws {
        // A download job with no stream selection goes to `probingStreams` first. A
        // metadata job must not: there is no manifest to probe, and the engine is not
        // involved at all.
        let coordinator = DownloadCoordinator()
        let id = coordinator.addMetadataJob(metadata: MetadataOptions())
        coordinator.startJob(id: id)

        let job = try #require(coordinator.jobs.first { $0.id == id })
        #expect(job.state != .running(.probingStreams))
    }
}

/// Tests for folding one progress bar per stream into a job's state.
///
/// The engine prints a row for every selected stream, back to back with no separator,
/// so these guard the thing that broke: a single-slot `progress` field meant the last
/// row of the table won, and a job downloading video displayed the subtitle task's 0%.
struct DownloadJobStreamProgressTests {

    private func progress(
        _ description: String,
        percent: Double,
        completed: Int = 0,
        total: Int = 100,
        speed: String = ""
    ) -> EngineOutputParser.Progress {
        EngineOutputParser.Progress(
            streamDescription: description,
            completedSegments: completed,
            totalSegments: total,
            percent: percent,
            retryAttempt: nil,
            sizeText: "",
            speedText: speed,
            etaText: "--:--:--"
        )
    }

    @Test("Readings are kept per stream, in the order the engine first mentioned them")
    func keepsOneReadingPerStream() {
        var job = DownloadJob(options: DownloadOptions())
        job.record(progress("Vid 640x360 | 800 Kbps", percent: 25, completed: 1, total: 4))
        job.record(progress("Aud English Audio | en", percent: 0))
        job.record(progress("Sub en | English", percent: 0))
        // A later repaint of the same stream replaces its reading rather than adding one.
        job.record(progress("Vid 640x360 | 800 Kbps", percent: 50, completed: 2, total: 4))

        #expect(job.streamProgress.count == 3, "repaints accumulated instead of replacing")
        #expect(
            job.streamProgress.map(\.streamDescription) == [
                "Vid 640x360 | 800 Kbps", "Aud English Audio | en", "Sub en | English",
            ])
        #expect(job.streamProgress.first?.percent == 50)
    }

    @Test("The active stream is the one with a rate, not the one printed last")
    func activeStreamIsTheOneTransferring() throws {
        // This is the reported symptom: video at 50% while the subtitle row, printed
        // last, still reads 0%. The engine prints "-" for a rate on any task it has not
        // started or has finished, so a speed identifies the one actually running.
        var job = DownloadJob(options: DownloadOptions())
        job.record(
            progress(
                "Vid 640x360 | 800 Kbps", percent: 50, completed: 2, total: 4,
                speed: "256.00KBps"))
        job.record(progress("Aud English Audio | en", percent: 0))
        job.record(progress("Sub en | English", percent: 0))

        let active = try #require(job.activeStream)
        #expect(active.streamDescription == "Vid 640x360 | 800 Kbps")
        #expect(active.percent == 50)

        let position = try #require(job.activeStreamPosition)
        #expect(position == (index: 1, count: 3))
    }

    @Test("Once a stream finishes, the next unfinished one becomes active")
    func activeStreamMovesOn() throws {
        var job = DownloadJob(options: DownloadOptions())
        job.record(progress("Vid 640x360 | 800 Kbps", percent: 100, completed: 4, total: 4))
        job.record(
            progress(
                "Aud English Audio | en", percent: 33.33, completed: 1, total: 3,
                speed: "56.00KBps"))

        #expect(job.activeStream?.streamDescription == "Aud English Audio | en")
        let position = try #require(job.activeStreamPosition)
        #expect(position == (index: 2, count: 2))
    }

    @Test("With every rate gone, the first unfinished stream is still reported")
    func activeStreamDuringMerge() {
        // During the ffmpeg merge every task has finished, so no row has a rate. The
        // job still needs something to name.
        var job = DownloadJob(options: DownloadOptions())
        job.record(progress("Vid 640x360 | 800 Kbps", percent: 100, completed: 4, total: 4))
        job.record(progress("Aud English Audio | en", percent: 100, completed: 3, total: 3))

        #expect(job.activeStream?.streamDescription == "Aud English Audio | en")
    }

    @Test("Overall progress is weighted by kind, not summed from counts nor averaged")
    func overallPercentIsWeighted() throws {
        // Without the engine's selection list (see `StreamWeightingTests` for the real
        // thing) the weights fall back to the kind of stream. Summing counts would be wrong
        // twice over: an unstarted stream reports 0/100 — Spectre's default MaxValue — so a
        // pending one-segment subtitle track would outweigh a four-segment video. And a plain
        // mean (this test used to assert one) counts a subtitle track as much as the video.
        var job = DownloadJob(options: DownloadOptions())
        job.record(progress("Vid 640x360 | 800 Kbps", percent: 50, completed: 2, total: 4))
        job.record(progress("Aud English Audio | en", percent: 0))
        job.record(progress("Sub en | English", percent: 0))

        let video = StreamEstimate.defaultWeight(for: .video)
        let audio = StreamEstimate.defaultWeight(for: .audio)
        let subtitle = StreamEstimate.defaultWeight(for: .subtitle)
        let expected = 50.0 * video / (video + audio + subtitle)

        let overall = try #require(job.overallPercent)
        #expect(abs(overall - expected) < 1e-9, "got \(overall)")
        #expect(overall > 50.0 / 3, "no better than a plain average")

        // Summing the printed counts would give 2/204 — under 1% — for a job that is well
        // on its way.
        let summed = job.streamProgress.reduce(0) { $0 + $1.completedSegments }
        let summedTotal = job.streamProgress.reduce(0) { $0 + $1.totalSegments }
        #expect(Double(summed) / Double(summedTotal) * 100 < 1)
    }

    @Test("Overall progress never walks backwards as tracks are handed over")
    func overallPercentIsMonotonic() {
        // Following the active stream instead would send the bar to zero at every track
        // boundary, which is what a per-track bar does in the CLI but is wrong for a
        // single bar summarising the job.
        var job = DownloadJob(options: DownloadOptions())
        var readings: [Double] = []

        job.record(progress("Vid", percent: 0))
        job.record(progress("Aud", percent: 0))
        readings.append(job.overallPercent ?? -1)
        job.record(progress("Vid", percent: 100))
        readings.append(job.overallPercent ?? -1)
        job.record(progress("Aud", percent: 50))
        readings.append(job.overallPercent ?? -1)
        job.record(progress("Aud", percent: 100))
        readings.append(job.overallPercent ?? -1)

        #expect(readings.first == 0)
        #expect(readings.last.map { abs($0 - 100) < 1e-9 } == true)
        #expect(zip(readings, readings.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("A job with no readings yet has no overall progress and no active stream")
    func emptyProgress() {
        let job = DownloadJob(options: DownloadOptions())
        #expect(job.overallPercent == nil)
        #expect(job.activeStream == nil)
        #expect(job.activeStreamPosition == nil)
    }

    @Test("A single-stream job reports no track position, since it adds nothing")
    func singleStreamHasNoPosition() {
        var job = DownloadJob(options: DownloadOptions())
        job.record(progress("Vid Kbps", percent: 50, completed: 3, total: 6, speed: "1.00MBps"))

        #expect(job.activeStreamPosition == nil)
        #expect(job.activeStream?.streamDescription == "Vid Kbps")
    }
}

/// Tests for how a job reports a failure the engine only announced in its log.
struct DownloadJobVerdictTests {

    private func record(
        _ level: EngineOutputParser.Level,
        _ message: String
    ) -> EngineOutputParser.LogRecord {
        EngineOutputParser.LogRecord(timestamp: "10:00:00.000", level: level, message: message)
    }

    @Test("The cause is reported, not the bare Failed verdict")
    func lastErrorSkipsTheVerdict() {
        // The verdict is always the last ERROR record, so taking the last one blindly
        // showed "Failed" and buried the line above it that says why.
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(record(.warn, "The response ended prematurely. (ResponseEnded)"))
        job.log.append(record(.error, "Segment count check not pass, total: 8, downloaded: 6."))
        job.log.append(record(.error, "Failed"))

        #expect(job.lastErrorMessage == "Segment count check not pass, total: 8, downloaded: 6.")
    }

    @Test("A run with nothing but the verdict still reports something")
    func lastErrorWithOnlyAVerdict() {
        var job = DownloadJob(options: DownloadOptions())
        job.log.append(record(.info, "Start downloading..."))
        job.log.append(record(.error, "Failed"))

        // No cause was logged, so there is no message to prefer — the failure case
        // supplies its own wording rather than showing an empty error.
        #expect(job.lastErrorMessage == nil)
        #expect(!DownloadJob.Failure.engineReportedFailure(lastError: nil).message.isEmpty)
    }

    @Test("A reported failure needs no exit code to describe itself")
    func engineReportedFailureMessage() {
        // The point of this case existing: there is no non-zero code to quote, because
        // the engine exits 0 even when it declares the download failed.
        let withCause = DownloadJob.Failure.engineReportedFailure(
            lastError: "Segment count check not pass, total: 8, downloaded: 6.")
        #expect(withCause.message == "Segment count check not pass, total: 8, downloaded: 6.")

        let withoutCause = DownloadJob.Failure.engineReportedFailure(lastError: nil)
        #expect(withoutCause.message.contains("failed"))
        #expect(!withoutCause.message.contains("code"), "quoted an exit code that means nothing")
    }
}

/// Tests for the rule that decides whether a finished engine run succeeded.
///
/// This is the whole reason `engineOutcome` is a pure function: the coordinator's own
/// branch cannot be exercised without spawning the engine, and the rule it encodes is
/// counter-intuitive enough that it broke once already.
struct EngineOutcomeTests {

    @Test("🔴 A Failed verdict outranks a zero exit code")
    func verdictBeatsExitCode() throws {
        // The reported bug: the engine logs `ERROR: Failed` and exits 0, so the app
        // showed a broken download as finished.
        let failure = try #require(
            DownloadJob.engineOutcome(
                verdict: .failed,
                exitCode: 0,
                wasTerminatedBySignal: false,
                lastError: "Segment count check not pass, total: 8, downloaded: 6."
            )
        )
        #expect(
            failure
                == .engineReportedFailure(
                    lastError: "Segment count check not pass, total: 8, downloaded: 6."))
    }

    @Test("A clean run with the Done verdict succeeds")
    func doneAndZeroSucceeds() {
        #expect(
            DownloadJob.engineOutcome(
                verdict: .succeeded, exitCode: 0, wasTerminatedBySignal: false, lastError: nil
            ) == nil
        )
    }

    @Test("A run that reached no verdict is judged by its exit code")
    func noVerdictFallsBackToTheExitCode() throws {
        // Nothing to read a verdict from: a parse error, a missing input file or a crash
        // all end before the engine gets that far, and those really do exit non-zero.
        #expect(
            DownloadJob.engineOutcome(
                verdict: nil, exitCode: 0, wasTerminatedBySignal: false, lastError: nil
            ) == nil
        )

        let failure = try #require(
            DownloadJob.engineOutcome(
                verdict: nil, exitCode: 1, wasTerminatedBySignal: false, lastError: nil
            )
        )
        #expect(failure == .engineExited(code: 1, lastError: nil))
    }

    @Test("Being killed by a signal is a failure whatever else was seen")
    func signalIsAlwaysAFailure() throws {
        // The engine can print `Done` and then be terminated during its exit handling;
        // reporting that as success would hide a truncated output.
        let failure = try #require(
            DownloadJob.engineOutcome(
                verdict: .succeeded, exitCode: 0, wasTerminatedBySignal: true, lastError: nil
            )
        )
        #expect(failure == .engineExited(code: 0, lastError: nil))
    }

    @Test("The engine's own error text is carried into the failure")
    func causeIsCarried() throws {
        let failure = try #require(
            DownloadJob.engineOutcome(
                verdict: .failed, exitCode: 0, wasTerminatedBySignal: false,
                lastError: "The response ended prematurely. (ResponseEnded)"
            )
        )
        #expect(failure.message == "The response ended prematurely. (ResponseEnded)")
    }
}
