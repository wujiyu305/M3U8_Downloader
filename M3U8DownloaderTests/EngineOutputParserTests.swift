import Foundation
import Testing

@testable import M3U8Downloader

/// Tests for parsing the engine's console output.
///
/// The `realCapture` tests run against `Fixtures/engine-stdout-failed-download.txt`,
/// a byte-for-byte capture of an actual engine run. Hand-written strings are used
/// for edge cases, but anything about the overall shape of the output is asserted
/// against the real bytes — a parser that only handles idealised input is exactly
/// the failure mode worth guarding against here.
struct EngineOutputParserTests {

    // MARK: - Fixture loading

    /// Loaded from the test bundle. Fails loudly rather than silently skipping:
    /// a test that quietly passes because its input went missing is worse than no
    /// test at all.
    static func loadFixture(_ name: String) throws -> String {
        let data = try loadFixtureData(name)
        // The engine writes some files with a UTF-8 BOM; be tolerant here too.
        let bom = Data([0xEF, 0xBB, 0xBF])
        let body = data.starts(with: bom) ? data.dropFirst(bom.count) : data
        guard let text = String(data: body, encoding: .utf8) else {
            throw FixtureError.notUTF8(name)
        }
        return text
    }

    /// The fixture's raw bytes, for tests that need to assert on encoding details
    /// such as the BOM the engine emits.
    static func loadFixtureData(_ name: String) throws -> Data {
        let candidates = ["txt", "json"]
        for ext in candidates {
            if let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: ext)
                ?? Bundle.fixtureFallbackURL(name: name, extension: ext)
            {
                return try Data(contentsOf: url)
            }
        }
        throw FixtureError.notFound(name)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        case notUTF8(String)

        var description: String {
            switch self {
            case .notFound(let name):
                return "Fixture '\(name).txt' is missing from the test bundle."
            case .notUTF8(let name):
                return "Fixture '\(name).txt' is not valid UTF-8."
            }
        }
    }

    private final class BundleToken {}

    // MARK: - Real capture

    @Test("The real capture yields the log records the engine actually printed")
    func realCaptureLogRecords() throws {
        let text = try Self.loadFixture("engine-stdout-failed-download")
        let records = EngineOutputParser.logRecords(in: text)

        // The capture contains 14 timestamped records, verified with grep.
        #expect(records.count >= 10, "expected the capture's records, got \(records.count)")

        let messages = records.map(\.message)
        #expect(messages.contains { $0.contains("N_m3u8DL-RE (Beta version)") })
        #expect(messages.contains { $0.contains("Loading URL") })
        #expect(records.contains { $0.level == .warn })
    }

    @Test("Records that the engine ran together are split apart, not merged")
    func realCaptureSplitsRunTogetherRecords() throws {
        let text = try Self.loadFixture("engine-stdout-failed-download")
        let records = EngineOutputParser.logRecords(in: text)

        // In the raw bytes this appears as
        //   "Content Matched: HTTP Live Streaming10:24:55.718 INFO : Parsing streams..."
        // with no newline between the two records. Each must come out separately,
        // and the first must not have the next record's timestamp glued on.
        let matched = records.first { $0.message.contains("Content Matched") }
        #expect(matched != nil, "the 'Content Matched' record went missing")
        if let matched {
            #expect(
                matched.message == "Content Matched: HTTP Live Streaming",
                "record still has the next one appended: \(matched.message)"
            )
        }
        #expect(records.contains { $0.message.contains("Parsing streams") })
    }

    @Test("The tput noise the engine's exit handler produces is filtered out")
    func realCaptureFiltersToolNoise() throws {
        let text = try Self.loadFixture("engine-stdout-failed-download")
        let records = EngineOutputParser.logRecords(in: text)

        #expect(
            !records.contains { $0.message.contains("tput:") },
            "tput noise leaked into the parsed records"
        )
    }

    @Test("Progress is recovered from the real interleaved output")
    func realCaptureProgress() throws {
        let text = try Self.loadFixture("engine-stdout-failed-download")
        let progress = EngineOutputParser.latestProgress(in: text)

        #expect(progress != nil, "no progress found in a capture that contains a progress bar")
        if let progress {
            #expect(progress.totalSegments == 3)
            #expect(progress.completedSegments == 0)
            // The capture ends mid-retry, so the retry counter must be picked up.
            #expect(progress.retryAttempt == 3)
        }
    }

    @Test("Both progress and log events come out of one interleaved chunk")
    func realCaptureMixedEvents() throws {
        let text = try Self.loadFixture("engine-stdout-failed-download")
        let events = EngineOutputParser.events(in: text)

        let logs = events.compactMap { event -> EngineOutputParser.LogRecord? in
            if case .log(let record) = event { return record }
            return nil
        }
        let progresses = events.compactMap { event -> EngineOutputParser.Progress? in
            if case .progress(let progress) = event { return progress }
            return nil
        }

        #expect(!logs.isEmpty, "no log events extracted")
        #expect(!progresses.isEmpty, "no progress events extracted")
    }

    // MARK: - A real download in flight

    @Test("Every stage of a real download is read, not just the ends")
    func realCaptureProgressAdvances() throws {
        // The bug this guards: the parser matched only the first repaint (0%, where
        // the size column is a dash) and the last (100%, where the speed column is),
        // so the bar sat at 0% for the whole download and then jumped. Nothing
        // errored — a token that does not match is simply not an event.
        let text = try Self.loadFixture("engine-stdout-progress")
        let percentages = EngineOutputParser.events(in: text).compactMap { event -> Double? in
            if case .progress(let progress) = event { return progress.percent }
            return nil
        }

        #expect(percentages.first == 0)
        #expect(percentages.last == 100)
        // 0 and 100 alone are what the broken parser produced. The intermediate
        // readings are the point.
        let intermediate = Set(percentages.filter { $0 > 0 && $0 < 100 })
        #expect(
            intermediate == [16.67, 33.33, 50, 66.67, 83.33],
            "expected every sixth of the way; got \(intermediate.sorted())"
        )
    }

    @Test("Speed and transferred size are recovered from the real capture")
    func realCaptureCarriesSpeedAndSize() throws {
        let text = try Self.loadFixture("engine-stdout-progress")
        let progresses = EngineOutputParser.events(in: text).compactMap {
            event -> EngineOutputParser.Progress? in
            if case .progress(let progress) = event { return progress }
            return nil
        }

        #expect(
            progresses.contains { $0.speedText == "304.00KBps" },
            "no speed was parsed from a capture that shows one throughout"
        )
        #expect(
            progresses.contains { $0.sizeText == "608.00KB/3.56MB" },
            "no downloaded/total size was parsed"
        )
        #expect(
            progresses.contains { $0.etaText == "00:00:02" },
            "no ETA was parsed"
        )
        // The final repaint reports the cumulative size with no rate.
        let last = try #require(progresses.last)
        #expect(last.sizeText == "2.34MB")
        #expect(last.speedText == "")
    }

    @Test("Log records come out clean, not padded with progress-bar residue")
    func realCaptureProgressKeepsLogs() throws {
        // Through `events(in:)`, which is what the coordinator calls — `logRecords`
        // on raw text deliberately does not strip progress output, so testing that
        // entry point would prove nothing about what the window shows.
        let text = try Self.loadFixture("engine-stdout-progress")
        let records = EngineOutputParser.events(in: text).compactMap {
            event -> EngineOutputParser.LogRecord? in
            if case .log(let record) = event { return record }
            return nil
        }

        // The engine logs `ResString.startDownloading + streamSpec.ToShortString()`, so
        // the stream name really is part of this message — only the *bar's* own
        // description and glyphs are residue. An earlier version stripped any trailing
        // description, which cut real text off this record.
        #expect(records.contains { $0.message == "Start downloading...Vid Kbps" })
        #expect(records.contains { $0.message == "ffmpeg merging..." })
        #expect(
            !records.contains { $0.message.contains("\u{2501}") },
            "progress-bar glyphs leaked into the log records"
        )
        #expect(
            !records.contains { $0.message.contains("KBps") },
            "progress text leaked into the log records"
        )
        // The engine reprints the bar between records, so its description used to
        // accumulate on whichever record printed last: one record came out 2371
        // characters long, of which 2359 were repeats of `Vid Kbps` and bar glyphs.
        let longest = records.map(\.message.count).max() ?? 0
        #expect(longest < 200, "a record is \(longest) characters — residue is back")

        // The same text at the *start* of a record is real output and must survive.
        #expect(
            records.contains { $0.message == "Vid Kbps | 6 Segments | ~00m24s" },
            "stripping the bar description also ate a real log line"
        )
    }

    // MARK: - Levels and the engine's verdict

    @Test("ERROR and DEBUG records use a different separator and must still parse")
    func levelSeparatorVariants() {
        // 🔴 `Logger` pads the level name to five characters before the colon, so the
        // four-letter levels get a space the five-letter ones do not: `INFO : ` but
        // `ERROR: `. Requiring `LEVEL : ` dropped every ERROR and DEBUG record, which
        // is why a failing download looked silent in the window.
        let text = """
            10:24:55.715 INFO : starting\
            10:24:55.716 WARN : careful\
            10:24:55.717 ERROR: Segment count check not pass, total: 8, downloaded: 6.\
            10:24:55.718 DEBUG: noisy detail
            """
        let records = EngineOutputParser.logRecords(in: text)

        // Compared as whole arrays rather than by index: with the separator wrong this
        // list is two elements short, and a bare `records[2]` would trap and take the
        // rest of the suite down with it instead of reporting a failure.
        #expect(records.map(\.level) == [.info, .warn, .error, .debug])
        #expect(
            records.map(\.message) == [
                "starting",
                "careful",
                "Segment count check not pass, total: 8, downloaded: 6.",
                "noisy detail",
            ]
        )
    }

    @Test("The engine's Failed verdict is recognised")
    func failedVerdict() throws {
        let records = EngineOutputParser.logRecords(in: "10:24:55.718 ERROR: Failed")
        let record = try #require(records.first)
        #expect(EngineOutputParser.verdict(in: record) == .failed)
    }

    @Test("The Done verdict is recognised")
    func doneVerdict() throws {
        let records = EngineOutputParser.logRecords(in: "10:24:55.718 INFO : Done")
        let record = try #require(records.first)
        #expect(EngineOutputParser.verdict(in: record) == .succeeded)
    }

    @Test("Ordinary text mentioning failure is not read as the verdict")
    func verdictIsNotGuessedFromWording() {
        // The engine says "failed" in plenty of places; only its closing ERROR record
        // whose whole message is `Failed` is the verdict.
        for line in [
            "10:24:58.737 WARN : Download first segment failed!",
            "10:24:58.737 INFO : Failed",
            "10:24:58.737 ERROR: Failed to open input file",
        ] {
            let record = EngineOutputParser.logRecords(in: line).first
            #expect(record != nil)
            #expect(
                record.flatMap(EngineOutputParser.verdict(in:)) == nil,
                "read a verdict out of: \(line)"
            )
        }
    }

    @Test("tput noise glued onto the verdict does not take the record with it")
    func verdictSurvivesToolNoise() throws {
        // Verbatim tail of a failing run: the engine's last line has no newline, so its
        // exit handler's `tput` error lands on the end of it. Dropping any record that
        // matched the noise discarded the verdict itself — the most important record
        // the engine prints.
        let records = EngineOutputParser.logRecords(
            in: "12:15:50.144 ERROR: Failedtput: No value for $TERM and no -T specified"
        )
        let record = try #require(records.first)
        #expect(record.message == "Failed")
        #expect(EngineOutputParser.verdict(in: record) == .failed)
    }

    @Test("A record that is only tool noise is still dropped")
    func pureToolNoiseIsDropped() {
        let records = EngineOutputParser.logRecords(
            in: "12:15:50.144 ERROR: tput: No value for $TERM and no -T specified"
        )
        #expect(records.isEmpty)
    }

    @Test("A failing run's verdict and cause are both recovered from the real capture")
    func realCaptureFailedVerdict() throws {
        // 🔴 The engine exited **0** for this run. Reproduced by truncating two of eight
        // segment responses: retries are exhausted, the segment-count check fails, and
        // the engine logs `ERROR: Failed` — then exits 0 anyway, because
        // `CommandInvoker.InvokeArgs` calls `Environment.Exit` with System.CommandLine's
        // return value and discards the `Environment.ExitCode = 1` the handler set.
        // Judging success by the exit code reported this broken download as finished.
        let text = try Self.loadFixture("engine-stdout-failed-verdict")
        let records = EngineOutputParser.events(in: text).compactMap {
            event -> EngineOutputParser.LogRecord? in
            if case .log(let record) = event { return record }
            return nil
        }

        #expect(
            records.compactMap(EngineOutputParser.verdict(in:)) == [.failed],
            "the engine's own verdict is missing from a run it declared failed"
        )
        #expect(
            records.contains {
                $0.level == .error
                    && $0.message == "Segment count check not pass, total: 8, downloaded: 6."
            },
            "the ERROR record naming the cause is missing"
        )
        #expect(
            records.contains { $0.message.contains("The response ended prematurely") },
            "the WARN records for the exhausted retries are missing"
        )
    }

    // MARK: - One bar per stream

    @Test("Each stream's bar is labelled, so readings do not overwrite each other")
    func multiStreamDescriptions() throws {
        // 🔴 The bug this guards: the engine prints a row per selected stream, back to
        // back with no newline, so every repaint produced three readings. With no label
        // the last row won and a job downloading video displayed the subtitle task's
        // 0%. Verbatim from the capture.
        let text = try Self.loadFixture("engine-stdout-multi-stream")
        let progresses = EngineOutputParser.events(in: text).compactMap {
            event -> EngineOutputParser.Progress? in
            if case .progress(let progress) = event { return progress }
            return nil
        }

        let descriptions = Set(progresses.map(\.streamDescription))
        #expect(
            descriptions == [
                "Vid 640x360 | 800 Kbps",
                "Aud English Audio | en",
                "Sub en | English",
            ],
            "got \(descriptions.sorted())"
        )
    }

    @Test("The video stream's own progress is recoverable from a multi-stream capture")
    func multiStreamVideoProgress() throws {
        let text = try Self.loadFixture("engine-stdout-multi-stream")
        let video = EngineOutputParser.events(in: text).compactMap {
            event -> EngineOutputParser.Progress? in
            guard case .progress(let progress) = event,
                progress.streamDescription.hasPrefix("Vid")
            else { return nil }
            return progress
        }

        let percentages = Set(video.map(\.percent))
        #expect(
            percentages == [0, 25, 50, 75, 100],
            "the video track's own quarters are missing; got \(percentages.sorted())"
        )
        #expect(
            video.contains { $0.speedText == "256.00KBps" },
            "no speed on the video track"
        )
        #expect(
            video.contains { $0.sizeText == "768.00KB/3.00MB" },
            "no downloaded/total size on the video track"
        )
    }

    @Test("A stream the engine has not reached reports Spectre's default, not segments")
    func unstartedStreamReportsDefaultMaximum() {
        // Verbatim: a queued task shows 0/100 — 100 is Spectre's default MaxValue,
        // assigned before the engine knows the segment count — with dashes for size
        // and speed. Presenting "0/100 segments" would be inventing a number.
        let progress = EngineOutputParser.latestProgress(
            in: "Sub en | English       ━━━━ 0/100 0.00%               -     -      --:--:--"
        )
        #expect(progress?.streamDescription == "Sub en | English")
        #expect(progress?.totalSegments == 100)
        #expect(progress?.hasStarted == false)
        #expect(progress?.segmentCounts == nil)
        #expect(progress?.speedText == "")
    }

    @Test("A log line that names a stream is not eaten by the description pattern")
    func descriptionDoesNotSwallowLogText() {
        // `Selected streams:` prints a stream description into the log, and the bar's
        // own description follows it glued on. The pattern is tempered so it starts at
        // the *last* prefix, leaving the log text intact.
        let text =
            "10:24:55.721 INFO : Vid 640x360 | 800 Kbps | 30 | SDR"
            + "Vid 640x360 | 800 Kbps ━━━━ 2/4 50.00% 768.00KB/3.00MB256.00KBps00:00:02"
        let events = EngineOutputParser.events(in: text)

        let records = events.compactMap { event -> EngineOutputParser.LogRecord? in
            if case .log(let record) = event { return record }
            return nil
        }
        #expect(records.count == 1)
        #expect(records.first?.message == "Vid 640x360 | 800 Kbps | 30 | SDR")

        let progresses = events.compactMap { event -> EngineOutputParser.Progress? in
            if case .progress(let progress) = event { return progress }
            return nil
        }
        #expect(progresses.count == 1)
        #expect(progresses.first?.streamDescription == "Vid 640x360 | 800 Kbps")
    }

    // MARK: - Progress token shapes

    // Every literal below is copied from `Fixtures/engine-stdout-progress.txt`. The
    // tests these replaced used invented shapes that omitted the size column
    // entirely — which is precisely why the parser shipped unable to read a download
    // in flight. Do not "tidy" the spacing in these strings: the *absence* of
    // separators is the thing under test.

    @Test("The mid-download shape parses, missing separators and all")
    func progressInFlight() {
        // Verbatim: the size column runs straight into the speed, and the speed
        // straight into the ETA, with no spaces anywhere.
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━━ 2/6 33.33% 608.00KB/3.56MB304.00KBps00:00:02"
        )
        #expect(progress?.completedSegments == 2)
        #expect(progress?.totalSegments == 6)
        #expect(progress?.percent == 33.33)
        #expect(progress?.sizeText == "608.00KB/3.56MB")
        #expect(progress?.speedText == "304.00KBps")
        #expect(progress?.etaText == "00:00:02")
        #expect(progress?.retryAttempt == nil)
    }

    @Test("A size column that is still a dash is not mistaken for the speed")
    func progressWithoutSizeYet() {
        // Verbatim. Until the first whole-second tick the size column is "-", glued
        // to the speed: `-304.00KBps`. Reading that as the speed — which the previous
        // pattern did — is what left the bar stuck.
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━━ 1/6 16.67% -304.00KBps00:00:01"
        )
        #expect(progress?.sizeText == "", "the placeholder dash leaked through as a size")
        #expect(progress?.speedText == "304.00KBps")
        #expect(progress?.etaText == "00:00:01")
        // 16.67 / 100 is not exactly 0.1667 in binary, so compare with a tolerance
        // rather than weakening the assertion to something vaguer.
        #expect(abs((progress?.fraction ?? 0) - 0.1667) < 1e-9)
    }

    @Test("The completed token parses, where it is the speed column that becomes a dash")
    func progressCompleted() {
        // Verbatim: no space between the percentage and the size, one cumulative size
        // rather than a pair, and the speed replaced by "-".
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━━6/6 100.00%2.34MB - 00:00:00"
        )
        #expect(progress?.completedSegments == 6)
        #expect(progress?.percent == 100)
        #expect(progress?.sizeText == "2.34MB")
        #expect(progress?.speedText == "")
        #expect(progress?.etaText == "00:00:00")
        #expect(progress?.fraction == 1)
    }

    @Test("A retry counter after the speed is captured")
    func progressWithRetry() {
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━━ 0/3 0.00% -0.00Bps(2) --:--:--"
        )
        #expect(progress?.retryAttempt == 2)
        #expect(progress?.speedText == "0.00Bps")
        #expect(progress?.etaText == "--:--:--")
    }

    @Test("An unknown ETA is preserved rather than invented")
    func progressUnknownETA() {
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━━ 0/3 0.00% -0.00Bps --:--:--"
        )
        #expect(progress?.etaText == "--:--:--")
        #expect(progress?.fraction == 0)
    }

    @Test("A token whose trailing columns are missing still moves the bar")
    func progressCoreOnly() {
        // The trailing groups are optional on purpose: if a column changes shape
        // again, the percentage must keep working rather than freezing the bar at
        // whatever it last read.
        let progress = EngineOutputParser.latestProgress(in: "Vid Kbps ━━ 2/4 50.00%")
        #expect(progress?.fraction == 0.5)
        #expect(progress?.sizeText == "")
        #expect(progress?.speedText == "")
        #expect(progress?.etaText == "")
    }

    @Test("fraction comes from the percentage, not from dividing the counts")
    func progressFractionUsesPercent() throws {
        // For a single-segment stream the engine overwrites the counts with byte
        // totals, so dividing them is only accidentally right. Here the two disagree
        // and the percentage must win.
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━ 12345678/17825792 69.26% 11.77MB/17.00MB2.40MBps00:00:02"
        )
        #expect(abs((progress?.fraction ?? 0) - 0.6926) < 1e-9)
        #expect(progress?.segmentCounts == nil, "byte counts were offered as segment counts")
    }

    @Test("Plausible segment counts are offered for display")
    func progressSegmentCounts() throws {
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━ 42/120 35.00% 8.20MB/23.43MB3.20MBps00:01:12"
        )
        let counts = try #require(progress?.segmentCounts)
        #expect(counts.completed == 42)
        #expect(counts.total == 120)
    }

    @Test("A single segment with no Content-Length reports 0% throughout, and says so")
    func progressSingleSegmentWithoutLength() {
        // Verbatim from a reproduction: one segment, a server sending chunked with no
        // Content-Length and no range support. The engine cannot split the file and
        // never learns its size, so it prints `0/1 0.00%` for the whole download —
        // 52 repaints over five seconds — and only the speed moves.
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━━ 0/1 0.00% -585.94KBps --:--:--"
        )
        // The dash is the size column. Reading it as part of the rate is what produced
        // the nonsensical "-585.94KBps" the window used to show.
        #expect(progress?.speedText == "585.94KBps")
        #expect(progress?.sizeText == "")
        #expect(progress?.percent == 0)
        // Nothing to draw a bar position from, which is why the row falls back to an
        // indeterminate bar rather than showing one frozen at zero.
        #expect(progress?.isDeterminate == false)
    }

    @Test("A non-zero reading is determinate")
    func progressBecomesDeterminate() {
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━ 1/6 16.67% -304.00KBps00:00:01"
        )
        #expect(progress?.isDeterminate == true)
    }

    @Test("A zero total does not divide by zero")
    func progressZeroTotal() {
        let progress = EngineOutputParser.latestProgress(
            in: "Vid Kbps ━━━ 0/0 0.00% -0.00Bps --:--:--"
        )
        #expect(progress?.fraction == 0)
        #expect(progress?.segmentCounts == nil)
    }

    @Test("The last of several repaints wins")
    func progressTakesLatest() {
        let text = """
            ━ 1/3 33.33% 1.00MBps 00:00:05\
            ━ 2/3 66.67% 1.00MBps 00:00:02
            """
        #expect(EngineOutputParser.latestProgress(in: text)?.completedSegments == 2)
    }

    // MARK: - Log records

    @Test("All engine log levels are recognised")
    func allLevels() {
        let text =
            "10:00:00.001 INFO : a10:00:00.002 WARN : b"
            + "10:00:00.003 ERROR : c10:00:00.004 DEBUG : d"
        let records = EngineOutputParser.logRecords(in: text)

        #expect(records.map(\.level) == [.info, .warn, .error, .debug])
        #expect(records.map(\.message) == ["a", "b", "c", "d"])
    }

    @Test("The timestamp is kept verbatim, not converted to a Date")
    func timestampIsVerbatim() {
        // The engine prints no date, so building a Date would mean inventing one
        // and would misbehave across midnight.
        let records = EngineOutputParser.logRecords(in: "10:24:55.718 INFO : hello")
        #expect(records.first?.timestamp == "10:24:55.718")
    }

    @Test("Text before the first timestamp is discarded as progress residue")
    func leadingResidueIsDropped() {
        let records = EngineOutputParser.logRecords(
            in: "Vid Kbps ━━━ --:--:--10:24:58.737 WARN : Permission denied"
        )
        #expect(records.count == 1)
        #expect(records.first?.message == "Permission denied")
    }

    @Test("Output with no timestamps yields no records")
    func noRecords() {
        #expect(EngineOutputParser.logRecords(in: "").isEmpty)
        #expect(EngineOutputParser.logRecords(in: "no timestamps here").isEmpty)
    }

    @Test("tput noise is identified")
    func toolNoiseDetection() {
        #expect(EngineOutputParser.isToolNoise("tput: No value for $TERM and no -T specified"))
        #expect(!EngineOutputParser.isToolNoise("Start downloading..."))
    }

    // MARK: - Milestones

    @Test(
        "Milestones are detected from real message text",
        arguments: [
            ("Parsing streams...", EngineOutputParser.Milestone.parsingStreams),
            ("Start downloading...", .startedDownloading),
            ("ffmpeg merging...", .muxing),
            ("Done", .done),
        ]
    )
    func milestoneDetection(message: String, expected: EngineOutputParser.Milestone) {
        #expect(EngineOutputParser.Milestone.detect(in: message) == expected)
    }

    @Test("Ordinary messages are not milestones")
    func nonMilestone() {
        #expect(EngineOutputParser.Milestone.detect(in: "Writing meta json") == nil)
    }
}

// MARK: - Fixture lookup fallback

extension Bundle {
    /// Xcode copies test resources into the test bundle, but the lookup path
    /// differs between SwiftPM and Xcode targets. This fallback keeps the fixture
    /// findable either way instead of failing opaquely.
    static func fixtureFallbackURL(name: String, extension ext: String = "txt") -> URL? {
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
            if let url = bundle.url(
                forResource: name, withExtension: ext, subdirectory: "Fixtures")
            {
                return url
            }
        }
        return nil
    }
}
