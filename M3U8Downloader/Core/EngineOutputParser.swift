import Foundation

/// Parses the download engine's console output into structured events.
///
/// ## Why this cannot be a line-based parser
///
/// The engine's output is **not** newline-delimited. Two measured reasons:
///
/// 1. `Logger.HandleLog` uses Spectre's `Markup` (no trailing newline) for the
///    first half of any log call that has a `subWrite` part, so records run
///    together: `Content Matched: HTTP Live Streaming10:24:55.718 INFO : Parsing…`
/// 2. The Spectre progress bar repaints continuously into the same stream, so
///    progress text is interleaved with log records without separators.
///
/// A capture of a real run contained 31 newline bytes for 14 log records — the
/// newlines do not mark record boundaries. Splitting on `\n` therefore yields
/// merged garbage. This parser instead scans for the two shapes that *are*
/// reliable: the `HH:mm:ss.SSS LEVEL :` log prefix, and the progress token.
///
/// The fixture `Fixtures/engine-stdout-failed-download.txt` is a byte-for-byte
/// capture of a real run and is what the tests assert against.
nonisolated struct EngineOutputParser {

    // MARK: - Events

    enum Level: String, Sendable {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
        case extra = "EXTRA"
    }

    struct LogRecord: Equatable, Sendable {
        /// Wall-clock stamp as printed, e.g. `10:24:55.718`. Kept as text because
        /// the engine prints no date, so building a `Date` would require guessing
        /// one and would break across midnight.
        let timestamp: String
        let level: Level
        let message: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.timestamp == rhs.timestamp && lhs.level == rhs.level
                && lhs.message == rhs.message
        }
    }

    struct Progress: Equatable, Sendable {
        /// Which stream this reading belongs to, as the engine labels its own progress
        /// bar: `Vid 640x360 | 800 Kbps`, `Aud English Audio | en`, `Sub en | English`.
        ///
        /// 🔴 **The engine runs one progress bar per selected stream and reprints all
        /// of them, back to back, with no newlines between them.** Without this label
        /// every repaint collapsed into a single reading and the last row of the table
        /// won — so a job downloading video first showed the *subtitle* task's 0%
        /// while the video sat at 50%. Measured in
        /// `Fixtures/engine-stdout-multi-stream.txt`.
        ///
        /// Empty when a token had no bar of its own to be labelled by.
        let streamDescription: String
        /// `task.Value` / `task.MaxValue` as the engine printed them. Usually
        /// segments — but **bytes** for a single-segment stream, where
        /// `DownloadSpeedColumn` overwrites both with the byte counts. Use
        /// `segmentCounts` rather than reading these directly for display.
        let completedSegments: Int
        let totalSegments: Int
        /// As printed by the engine, 0–100. Authoritative for the progress bar
        /// because it is correct in both the segment and the byte mode above.
        let percent: Double
        /// Low-speed counter the engine appends to the speed, e.g. `0.00Bps(3)`.
        /// `nil` when the download is moving.
        let retryAttempt: Int?
        /// Downloaded / estimated total, e.g. `608.00KB/3.56MB`, or a single
        /// cumulative size once finished. Empty while the engine prints `-`, which
        /// it does until the first whole-second tick.
        ///
        /// The total is extrapolated from the ratio so far
        /// (`DownloadStatusColumn`: `size / (value / max)`), so it moves around
        /// early in a download. That is the engine's own number, shown as-is.
        let sizeText: String
        /// Current rate, e.g. `304.00KBps`. Empty once finished, when the engine
        /// replaces it with `-`.
        ///
        /// Only the stream actually transferring has one: a queued or finished task
        /// prints `-`, which is what `DownloadJob.activeStream` keys off.
        let speedText: String
        /// `--:--:--` while unknown.
        let etaText: String

        /// Progress as a 0–1 fraction, taken from the engine's own percentage.
        ///
        /// **Not** `completed / total`: those are byte counts for a single-segment
        /// stream, and dividing them is only accidentally right. The percentage is
        /// computed by Spectre from the same two numbers and is correct in both
        /// modes.
        ///
        /// 🔴 **A download can legitimately report 0% from start to finish, and that
        /// is the engine's doing, not a parsing failure.** Reproduced: a stream with
        /// exactly one segment whose server sends no `Content-Length` and no range
        /// support. `SimpleDownloadManager` then cannot split the file
        /// (`LargeSingleFileSplitUtil`) and sets `SingleSegment`, but with no
        /// `ResponseLength` `DownloadSpeedColumn` never swaps the counts for bytes —
        /// so `MaxValue` stays 1 and `Value` stays 0 until the segment lands.
        /// Measured over a 5-second download: 52 repaints of `0/1 0.00%`, then
        /// `1/1 100.00%`. Only the speed moves. `isDeterminate` exists so the UI can
        /// show an indeterminate bar rather than one frozen at zero, which is what
        /// made this look like an app bug.
        var fraction: Double { min(max(percent / 100, 0), 1) }

        /// Whether the percentage is worth drawing as a bar position.
        ///
        /// False at 0%, where the engine may be reporting a genuine "no idea" — see
        /// `fraction`. It flips to true on the first non-zero reading.
        var isDeterminate: Bool { percent > 0 }

        /// Whether the engine has actually begun this stream.
        ///
        /// 🔴 A task the engine has not reached yet reports **`0/100`** — 100 being
        /// Spectre's default `MaxValue`, assigned before `DownloadStreamAsync` sets
        /// the real segment count — with `-` for both size and speed. Presenting that
        /// as "0 of 100 segments" would be inventing a number.
        var hasStarted: Bool {
            completedSegments > 0 || percent > 0 || !sizeText.isEmpty || !speedText.isEmpty
        }

        /// The counts, but only when they are plausibly segment counts.
        ///
        /// There is no marker in the output distinguishing the two modes, so this is
        /// a threshold: a stream with more than 100 000 segments is not something
        /// this app targets, while any real media file is far larger than 100 000
        /// bytes. Showing "1234567/17825792 segments" would be actively wrong, and
        /// `sizeText` already says it properly in that mode.
        var segmentCounts: (completed: Int, total: Int)? {
            guard hasStarted, totalSegments > 0, totalSegments < 100_000 else { return nil }
            return (completedSegments, totalSegments)
        }
    }

    enum Event: Equatable, Sendable {
        case log(LogRecord)
        case progress(Progress)
    }

    /// The engine's own final judgement on a run.
    ///
    /// 🔴 **This, not the exit code, is what says whether a download worked.**
    /// Measured: a download whose segment-count check fails logs
    /// `ERROR: Segment count check not pass, total: 8, downloaded: 6.` and then
    /// `ERROR: Failed` — and **exits 0**. `Program.DoWorkAsync` does set
    /// `Environment.ExitCode = 1`, but `CommandInvoker.InvokeArgs` ends with
    /// `Environment.Exit(await parseResult.InvokeAsync())`, and `System.CommandLine`
    /// returns 0 for a handler that completed without throwing, so that assignment is
    /// discarded.
    ///
    /// Both strings are hardcoded literals in `Program.DoWorkAsync`
    /// (`[white on green]Done[/]` and `[white on red]Failed[/]`), not localisable
    /// resources, so matching them exactly is safe.
    enum Verdict: Equatable, Sendable {
        case succeeded
        case failed
    }

    /// The verdict a record carries, if it is one.
    ///
    /// Level-aware on purpose: ordinary output contains the word "failed" often enough
    /// (`Download first segment failed!`), but only the engine's closing verdict is an
    /// ERROR record whose entire message is `Failed`.
    static func verdict(in record: LogRecord) -> Verdict? {
        switch (record.level, record.message) {
        case (.error, "Failed"): return .failed
        case (.info, "Done"): return .succeeded
        default: return nil
        }
    }

    /// The name the engine settled on for this download's files.
    ///
    /// When the user gives no save name the engine invents one — the manifest's file name
    /// plus a timestamp, e.g. `vod_main_JeyvV5ESJWYBatM_2026-09-14_11-41-45` — and this
    /// record is the only place that name is ever disclosed. It is what lets the app find
    /// the finished file afterwards.
    ///
    /// 🔴 **The prefix is a localised resource, not a literal.** `StaticText.cs` carries it
    /// as `Save Name: ` / `保存文件名: ` / `保存檔案名: `, and the engine picks among them from
    /// the *system* language unless `--ui-language` is passed. Measured: with
    /// `--ui-language zh-CN` the whole log is Chinese. `DownloadCoordinator` therefore pins
    /// `en-US`, and this only recognises the English form: if the pin is ever removed this
    /// silently stops matching rather than guessing at translations.
    static func saveName(in record: LogRecord) -> String? {
        let prefix = "Save Name: "
        guard record.level == .info, record.message.hasPrefix(prefix) else { return nil }
        let name = record.message.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: - Patterns

    /// `10:24:55.718 INFO : ` — and `10:24:55.718 ERROR: `.
    ///
    /// 🔴 **The separator depends on the level's length.** `Logger` pads the name to
    /// five characters before the colon, so the four-letter levels get a space the
    /// five-letter ones do not:
    ///
    /// ```
    /// INFO :   WARN :   ERROR:   DEBUG:   EXTRA:
    /// ```
    ///
    /// Requiring `LEVEL : ` therefore dropped **every ERROR and DEBUG record**, which
    /// is why a failing download looked silent: the engine's own
    /// `ERROR: Segment count check not pass…` and `ERROR: Failed` never reached the
    /// window, and `DownloadJob.lastErrorMessage` could never find an `.error` record
    /// to report. (EXTRA only ever goes to the log file, never to a stream, but it
    /// costs nothing to accept.)
    ///
    /// Anchored on the time shape rather than a line start, because records do not
    /// begin at line starts.
    ///
    /// Written as an explicit `Regex(...)` rather than a `/.../` literal: the
    /// pattern ends in `: ` and bare-slash syntax mis-parses that as Swift
    /// punctuation.
    private static let logPrefix = try! Regex(
        #"(\d{2}:\d{2}:\d{2}\.\d{3}) (INFO|WARN|ERROR|DEBUG|EXTRA) ?: "#
    )

    /// `GlobalUtil.FormatFileSize` always emits two decimals and a `B`/`KB`/`MB`/`GB`
    /// suffix. Longest suffix first, so `KB` is not read as `B`.
    private static let fileSizePattern = #"[\d.]+(?:GB|MB|KB|B)"#

    /// The size column: either `downloaded/total`, a single cumulative size, or `-`.
    ///
    /// The `(?!ps)` lookahead keeps a speed with no preceding size column from being
    /// read as a size — `1.00MBps` must not match as the size `1.00MB`.
    private static let sizePattern =
        #"(?:\#(fileSizePattern)(?!ps)(?:/\#(fileSizePattern)(?!ps))?|-)"#

    /// The speed column: a formatted size with `ps` appended, or `-` once finished.
    private static let speedPattern = #"(?:\#(fileSizePattern)ps|-)"#

    /// The task description that labels each bar, e.g. `Vid 640x360 | 800 Kbps`.
    ///
    /// `Vid`/`Aud`/`Sub` are hardcoded literals in `StreamSpec.ToShortShortString()`,
    /// not localised strings, so they are safe to anchor on.
    ///
    /// The inner `(?!Vid |Aud |Sub )` makes this a tempered match: the description may
    /// not contain another prefix, which forces the match to begin at the **last** one
    /// before the bar. Without that, a log line that itself names a stream
    /// (`Selected streams:` prints one) would be swallowed into the description and
    /// deleted from the log.
    ///
    /// 🔴 **The limit has to clear the longest real label.** It was 60, and an HDR HEVC video
    /// (`Vid 640x360 | 657 Kbps | 29.97 | hvc1.2.20000000.H120.B0 | PQ`, 62 characters) or
    /// `Aud audio-stereo-aac-128 | English Audio Descriptions | en | 2CH` (63) is longer. Such a
    /// row then failed to match as one piece: the stream got a truncated label
    /// (`Audio Descriptions | en | 2CH`), and everything before the cut was left behind as text
    /// that `ChunkAssembler` carried to the next piece — about 350 bytes per repaint, so that
    /// after an hour the carry was tens of kilobytes and the app froze. The limit is generous
    /// on purpose; a label beyond it is bounded by the carry cap instead.
    private static let descriptionPattern =
        #"(?:Vid|Aud|Sub)(?:(?!Vid |Aud |Sub )[^\u{2501}\u{2500}\n]){0,200}"#

    /// One repaint of one stream's progress bar.
    ///
    /// The columns are, in order (`SimpleDownloadManager.StartDownloadAsync`):
    /// description, bar, `MyPercentageColumn`, `DownloadStatusColumn` (size),
    /// `DownloadSpeedColumn`, `RemainingTimeColumn`. Measured examples, verbatim from
    /// `Fixtures/engine-stdout-progress.txt`:
    ///
    /// ```
    /// 0/6 0.00% -0.00Bps --:--:--       size is "-", speed is 0.00Bps
    /// 1/6 16.67% -304.00KBps00:00:01    still "-", and now nothing separates it
    ///                                   from the speed, nor the speed from the ETA
    /// 2/6 33.33% 608.00KB/3.56MB304.00KBps00:00:02
    /// 6/6 100.00%2.34MB - 00:00:00      finished: one size, and the speed becomes "-"
    /// ```
    ///
    /// 🔴 **The separators are not reliable.** Every column is right-justified or
    /// centred inside a width Spectre reallocates on each repaint, so between any two
    /// fields there may be one space or none — including between the percentage and
    /// the size, and between the speed and the ETA. Each field is therefore
    /// recognised by its own shape, with `\s*` between them.
    ///
    /// The previous pattern assumed single spaces and read whatever followed the
    /// percentage as the speed. Measured against the capture, what that actually broke
    /// was the **detail**, not the bar: the counts and the percentage still parsed,
    /// but the transferred size was never shown at all, and the speed came out as
    /// `608.00KB/3.56MB304.00KBps` mid-download — or as `-585.94KBps`, a fake
    /// negative, whenever the size column was still a dash.
    ///
    /// ⚠️ An earlier version of this comment claimed the old pattern failed to match
    /// mid-download, and that this was why the bar sat at 0%. That was wrong. Running
    /// the old pattern against `engine-stdout-progress.txt` disproves it: it yields
    /// the full 0 → 16.67 → … → 100 sequence, because the greedy `[^\s(]*` backtracks
    /// until the trailing ETA matches. A bar that really does sit at 0% has an
    /// engine-side cause — see `Progress.fraction`.
    ///
    /// Every trailing group is optional, so the counts and the percentage — the two
    /// that drive the bar — still parse if a column changes shape again.
    ///
    /// The leading description and bar are consumed as part of the token. Both matter:
    /// the description is what tells one stream's bar from another's (see
    /// `Progress.streamDescription`), and leaving either behind glued them into log
    /// messages — one record in a 7-second capture came out **2371 characters** long,
    /// almost all of it repeated bar glyphs and the same description over and over.
    private static let progressToken = try! Regex(
        #"(?:(\#(descriptionPattern))?\s*[\u{2501}\u{2500}]+\s*)?"#
            + #"(\d+)/(\d+)\s*(\d+(?:\.\d+)?)%"#
            + #"(?:\s*(\#(sizePattern)))?"#
            + #"(?:\s*(\#(speedPattern))(?:\((\d+)\))?)?"#
            + #"(?:\s*(--:--:--|\d{2}:\d{2}:\d{2}))?"#
    )

    /// The engine spawns `tput cnorm` on exit to restore the cursor
    /// (`Program.RestoreTerminal`). That child inherits our pipes, so its error
    /// shows up in both streams. Measured: `TERM=dumb` does not suppress it and no
    /// engine option disables it, so it is filtered here.
    static func isToolNoise(_ text: String) -> Bool {
        text.contains("tput:") && text.contains("TERM")
    }

    /// 🔴 That noise arrives **glued onto the last log record**, because the engine's
    /// final line has no trailing newline: the measured tail is
    /// `ERROR: Failedtput: No value for $TERM and no -T specified`.
    ///
    /// Dropping any record `isToolNoise` matched therefore discarded the engine's own
    /// verdict — the single most important record it prints. The noise is cut out of
    /// the message instead, and only a record left with nothing else is dropped.
    private static let toolNoisePattern = try! Regex(#"tput:[^\n]*"#)

    private static func removingToolNoise(from message: String) -> String {
        guard message.contains("tput:") else { return message }
        return message.replacing(toolNoisePattern, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    /// Extracts every event from a chunk of engine output.
    ///
    /// Progress tokens are matched first and removed, because a progress repaint
    /// can sit immediately before a timestamp (`--:--:--10:24:58.737 WARN : …`)
    /// and would otherwise be swallowed into the previous log message.
    static func events(in text: String) -> [Event] {
        let text = compactingRuns(text)
        var events: [Event] = []
        var remainder = ""
        var cursor = text.startIndex

        // Pass 1: pull out progress tokens, keeping the rest for log scanning.
        // `matches(of:)` reports ranges into `text` directly, avoiding the index
        // conversion that slicing would otherwise require.
        for match in text.matches(of: progressToken) {
            guard match.range.lowerBound >= cursor else { continue }
            remainder += text[cursor..<match.range.lowerBound]
            if let progress = makeProgress(from: match) {
                events.append(.progress(progress))
            }
            cursor = match.range.upperBound
        }
        remainder += text[cursor...]

        // Pass 2: split what is left on the log prefix.
        events.append(contentsOf: logRecords(in: remainder).map(Event.log))
        return events
    }

    /// Splits text on the timestamp prefix. Anything before the first prefix is
    /// dropped: it is progress-bar residue, not a message.
    static func logRecords(in text: String) -> [LogRecord] {
        let matches = text.matches(of: logPrefix)
        guard !matches.isEmpty else { return [] }

        var records: [LogRecord] = []
        for (offset, match) in matches.enumerated() {
            let messageStart = match.range.upperBound
            let messageEnd =
                offset + 1 < matches.count
                ? matches[offset + 1].range.lowerBound
                : text.endIndex

            let message = removingToolNoise(
                from: text[messageStart..<messageEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !message.isEmpty else { continue }
            guard let stamp = capture(match, 1), let levelText = capture(match, 2),
                let level = Level(rawValue: levelText)
            else { continue }

            records.append(
                LogRecord(timestamp: stamp, level: level, message: message)
            )
        }
        return records
    }

    private static let longestWhitespaceRun = 16
    private static let longestBarRun = 64
    private static let longestDigitRun = 24

    /// Caps long runs of whitespace, bar glyphs and digits, which the progress pattern scans
    /// in quadratic time.
    ///
    /// The pattern is tried at every position, and from each one it consumes the whole run
    /// before failing: a run of N spaces costs N² steps. Measured: 2 000 spaces take 0.18 s,
    /// so 64 KB would take minutes — on the main actor, every 120 ms. Real output never has
    /// runs this long (Spectre pads columns to tens of characters, a bar is 30 glyphs wide),
    /// but residue that nothing consumes can concatenate into one, and a frozen window is a
    /// poor way to find out. The limits are well above anything the engine prints, so
    /// ordinary text passes through unchanged.
    static func compactingRuns(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var whitespace = 0
        var bars = 0
        var digits = 0
        for character in text {
            if character.isWhitespace {
                whitespace += 1
                bars = 0
                digits = 0
                if whitespace > longestWhitespaceRun { continue }
            } else if character == "\u{2501}" || character == "\u{2500}" {
                bars += 1
                whitespace = 0
                digits = 0
                if bars > longestBarRun { continue }
            } else if character.isASCII, character.isNumber {
                digits += 1
                whitespace = 0
                bars = 0
                if digits > longestDigitRun { continue }
            } else {
                whitespace = 0
                bars = 0
                digits = 0
            }
            result.append(character)
        }
        return result
    }

    /// Splits `text` into what can be parsed now and an unfinished tail to carry forward.
    ///
    /// The coordinator reads the pipe in arbitrary pieces, and a piece may end anywhere —
    /// inside `ERROR: Failed`, inside a progress token, inside a timestamp. Parsing each
    /// piece on its own turned `ERROR: Fai` + `led` into a record reading `Fai`, which
    /// dropped the engine's verdict; and the engine exits 0 on a failed download, so the
    /// verdict is the only thing standing between a failure and a "succeeded" row.
    ///
    /// A record is closed only by the *next* log prefix (progress tokens inside it are
    /// removed and the rest joined — that is how `Unhandled exception:` text ends up on the
    /// record it followed). So:
    ///
    /// - everything before the **last log prefix** is whole records and is returned as is;
    /// - the last record may still be growing, so it stays in the tail;
    /// - **complete progress tokens in the tail are returned now** rather than carried.
    ///   Holding them behind the last record would freeze the progress bar for as long as
    ///   the engine stays quiet, which during a download is the whole download. "Complete"
    ///   means it carries an ETA: a token without one may be a bar cut short, with its size
    ///   and speed columns still to come.
    ///
    /// The tail therefore holds only the unfinished record's text (plus any partial token),
    /// and the next piece is appended to it before matching, so a token split across two
    /// pieces is whole again by then.
    static func splitUnfinishedTail(of text: String) -> (ready: String, tail: String) {
        let text = compactingRuns(text)
        guard let last = text.matches(of: logPrefix).last else {
            // No record has started; only tokens can be released.
            return releasingTokens(from: text, ready: "")
        }
        let cut = last.range.lowerBound
        return releasingTokens(
            from: String(text[cut...]), ready: String(text[..<cut]))
    }

    private static func releasingTokens(
        from tail: String, ready: String
    ) -> (ready: String, tail: String) {
        var ready = ready
        var remaining = ""
        var cursor = tail.startIndex
        for match in tail.matches(of: progressToken) where capture(match, 8) != nil {
            guard match.range.lowerBound >= cursor else { continue }
            remaining += tail[cursor..<match.range.lowerBound]
            ready += tail[match.range]
            cursor = match.range.upperBound
        }
        remaining += tail[cursor...]
        return (ready, remaining)
    }

    /// The most recent progress reading in a chunk, which is all the UI needs —
    /// intermediate repaints of the same bar carry no extra information.
    static func latestProgress(in text: String) -> Progress? {
        text.matches(of: progressToken).last.flatMap(makeProgress)
    }

    /// Runtime-built `Regex` yields `AnyRegexOutput`, so captures are read by
    /// index rather than as a typed tuple.
    private static func capture(_ match: Regex<AnyRegexOutput>.Match, _ index: Int) -> String? {
        guard index < match.output.count,
            let substring = match.output[index].substring
        else { return nil }
        return String(substring)
    }

    private static func makeProgress(from match: Regex<AnyRegexOutput>.Match) -> Progress? {
        guard let completedText = capture(match, 2),
            let totalText = capture(match, 3),
            let percentText = capture(match, 4),
            let completed = Int(completedText),
            let total = Int(totalText),
            let percent = Double(percentText)
        else { return nil }

        // `-` is the engine's placeholder for "nothing to report yet"; it is carried
        // as an empty string so the UI has one thing to test rather than two.
        let placeholder = "-"
        let size = capture(match, 5) ?? ""
        let speed = capture(match, 6) ?? ""

        return Progress(
            // The engine right-pads the description to align the bars.
            streamDescription: (capture(match, 1) ?? "")
                .trimmingCharacters(in: .whitespaces),
            completedSegments: completed,
            totalSegments: total,
            percent: percent,
            retryAttempt: capture(match, 7).flatMap { Int($0) },
            sizeText: size == placeholder ? "" : size,
            speedText: speed == placeholder ? "" : speed,
            etaText: capture(match, 8) ?? ""
        )
    }

    // MARK: - Notable messages

    /// Messages worth surfacing prominently, identified from real runs.
    enum Milestone: Equatable, Sendable {
        case parsingStreams
        case startedDownloading
        case muxing
        case done

        static func detect(in message: String) -> Milestone? {
            if message.contains("Parsing streams") { return .parsingStreams }
            if message.contains("Start downloading") { return .startedDownloading }
            if message.contains("merging") || message.contains("Muxing") { return .muxing }
            if message == "Done" || message.hasPrefix("Done") { return .done }
            return nil
        }
    }
}
