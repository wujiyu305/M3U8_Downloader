import Testing

@testable import M3U8Downloader

/// Tests for the options -> argv translation.
///
/// The properties that matter most are the *absences*: an option the user never
/// touched must not appear at all. A builder that helpfully emits defaults would
/// still "work" in casual use, which is exactly why that needs pinning down.
struct CommandBuilderTests {

    // MARK: - Only what was asked for

    /// What `DownloadOptions()` emits before the user changes anything.
    ///
    /// Merging is on by default — a deliberate departure from the engine, which
    /// merges only when given `-M`. Tests that check "nothing extra is emitted"
    /// compare against this rather than against the input alone, so the default
    /// stays visible instead of being quietly absorbed into every expectation.
    static let defaultExtraArguments = ["-M", "format=MP4"]

    @Test("A bare set of options emits only the input and the default merge")
    func minimalOptions() {
        var options = DownloadOptions()
        options.input = "https://example.com/stream.m3u8"

        #expect(
            CommandBuilder.arguments(for: options)
                == ["https://example.com/stream.m3u8"] + Self.defaultExtraArguments
        )
    }

    @Test("Merging is on by default, and off means no -M at all")
    func mergeIsOnByDefault() {
        var options = DownloadOptions()
        options.input = "x"
        // The default: one playable file rather than loose tracks.
        #expect(CommandBuilder.arguments(for: options).contains("-M"))
        #expect(options.merge.muxAfterDone != nil)

        // Turning it off is respected exactly — no flag, and nothing asked later.
        options.merge.muxAfterDone = nil
        #expect(!CommandBuilder.arguments(for: options).contains("-M"))
        #expect(CommandBuilder.arguments(for: options) == ["x"])
    }

    @Test("Input comes first, before any option")
    func inputIsPositionalAndFirst() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.basic.saveName = "episode"

        let argv = CommandBuilder.arguments(for: options)
        #expect(argv.first == "https://example.com/a.m3u8")
    }

    @Test("Untouched options emit nothing, so engine defaults stay in effect")
    func nilOptionsAreOmitted() {
        var options = DownloadOptions()
        options.input = "x"

        let argv = CommandBuilder.arguments(for: options)

        // --thread-count is the important one: its engine default is
        // Environment.ProcessorCount, so emitting any fixed number here would
        // silently override a machine-dependent default.
        #expect(!argv.contains("--thread-count"))
        #expect(!argv.contains("--del-after-done"))
        #expect(!argv.contains("--use-system-proxy"))
        #expect(!argv.contains("--sub-format"))
        #expect(!argv.contains("--log-level"))
        // `-M` is deliberately present: merging is this app's default, unlike the
        // engine's. Everything else must still be absent.
        #expect(argv == ["x"] + Self.defaultExtraArguments)
    }

    @Test("Empty strings are treated as unset rather than emitted blank")
    func emptyStringsAreOmitted() {
        var options = DownloadOptions()
        options.input = "x"
        options.basic.saveName = ""
        options.basic.saveDirectory = ""

        let argv = CommandBuilder.arguments(for: options)
        #expect(argv == ["x"] + Self.defaultExtraArguments)
    }

    // MARK: - Booleans

    @Test("Booleans are emitted with an explicit True/False value")
    func booleansUseExplicitValues() {
        var options = DownloadOptions()
        options.input = "x"
        options.selection.autoSelect = true
        options.merge.deleteAfterDone = false

        let argv = CommandBuilder.arguments(for: options)

        #expect(contains(argv, flag: "--auto-select", value: "True"))
        #expect(contains(argv, flag: "--del-after-done", value: "False"))
    }

    @Test("Turning off an option that defaults to true emits False")
    func disablingDefaultTrueOption() {
        var options = DownloadOptions()
        options.input = "x"
        // These four default to true in the engine, so "off" must be explicit.
        options.network.useSystemProxy = false
        options.selection.autoSubtitleFix = false
        options.advanced.checkSegmentsCount = false
        options.advanced.writeMetaJSON = false
        options.live.keepSegments = false

        let argv = CommandBuilder.arguments(for: options)

        #expect(contains(argv, flag: "--use-system-proxy", value: "False"))
        #expect(contains(argv, flag: "--auto-subtitle-fix", value: "False"))
        #expect(contains(argv, flag: "--check-segments-count", value: "False"))
        #expect(contains(argv, flag: "--write-meta-json", value: "False"))
        #expect(contains(argv, flag: "--live-keep-segments", value: "False"))
    }

    // MARK: - Repeatable options

    @Test("Each header becomes its own -H pair")
    func headersRepeatTheFlag() {
        var options = DownloadOptions()
        options.input = "x"
        options.network.headers = [
            .init(name: "Cookie", value: "a=1; b=2"),
            .init(name: "User-Agent", value: "Mozilla/5.0"),
        ]

        let argv = CommandBuilder.arguments(for: options)

        #expect(argv.filter { $0 == "-H" }.count == 2)
        #expect(argv.contains("Cookie: a=1; b=2"))
        #expect(argv.contains("User-Agent: Mozilla/5.0"))
    }

    @Test("Headers with an empty name are skipped")
    func blankHeadersAreSkipped() {
        var options = DownloadOptions()
        options.input = "x"
        options.network.headers = [.init(name: "", value: "ignored")]

        #expect(CommandBuilder.arguments(for: options) == ["x"] + Self.defaultExtraArguments)
    }

    @Test("Keys, ad keywords and mux imports repeat their flag once per value")
    func repeatableOptionsRepeatFlags() {
        var options = DownloadOptions()
        options.input = "x"
        options.merge.keys = ["kid1:key1", "kid2:key2"]
        options.selection.adKeywords = ["/ad/", "/promo/"]
        options.merge.muxImports = ["path=a.srt:lang=eng"]

        let argv = CommandBuilder.arguments(for: options)

        #expect(argv.filter { $0 == "--key" }.count == 2)
        #expect(argv.filter { $0 == "--ad-keyword" }.count == 2)
        #expect(argv.filter { $0 == "--mux-import" }.count == 1)
    }

    // MARK: - Numbers

    @Test("A whole-number timeout renders without a decimal point")
    func timeoutRendersAsInteger() {
        var options = DownloadOptions()
        options.input = "x"
        options.network.httpRequestTimeout = 100

        #expect(
            contains(
                CommandBuilder.arguments(for: options),
                flag: "--http-request-timeout", value: "100"))
    }

    @Test("A fractional timeout keeps its decimals")
    func fractionalTimeoutIsPreserved() {
        var options = DownloadOptions()
        options.input = "x"
        options.network.httpRequestTimeout = 2.5

        #expect(
            contains(
                CommandBuilder.arguments(for: options),
                flag: "--http-request-timeout", value: "2.5"))
    }

    // MARK: - Mux options

    @Test("Mux renders as a colon-separated key=value list, omitting defaults")
    func muxRendersDefaultsCompactly() {
        let mux = MuxAfterDone(format: .mkv)
        // muxer=ffmpeg is the engine default, so it should not appear.
        #expect(CommandBuilder.render(mux) == "format=MKV")
    }

    @Test("Non-default mux settings all appear")
    func muxRendersNonDefaults() {
        let mux = MuxAfterDone(
            format: .mkv,
            muxer: .mkvmerge,
            binPath: "/opt/homebrew/bin/mkvmerge",
            keep: true,
            skipSubtitles: true
        )

        #expect(
            CommandBuilder.render(mux)
                == "format=MKV:muxer=mkvmerge:bin_path=/opt/homebrew/bin/mkvmerge:keep=true:skip_sub=true"
        )
    }

    @Test("mkvmerge with MP4 is rejected regardless of case")
    func mkvmergeCannotDoMP4() {
        // The engine's own guard compares the raw format string to lowercase
        // "mp4" while parsing uppercases it, so `format=MP4:muxer=mkvmerge`
        // slips past upstream and fails later. This must be caught here.
        let invalid = MuxAfterDone(format: .mp4, muxer: .mkvmerge)
        #expect(!invalid.isValid)
        #expect(invalid.validationMessage != nil)

        #expect(MuxAfterDone(format: .mkv, muxer: .mkvmerge).isValid)
        #expect(MuxAfterDone(format: .mp4, muxer: .ffmpeg).isValid)
    }

    // MARK: - Shell rendering

    @Test("Safe tokens are left unquoted")
    func safeTokensAreBare() {
        #expect(
            CommandBuilder.shellQuote("https://example.com/a.m3u8")
                == "https://example.com/a.m3u8")
        #expect(CommandBuilder.shellQuote("--save-name") == "--save-name")
    }

    @Test("Tokens the shell would expand are single-quoted")
    func expandableTokensAreQuoted() {
        // Double quotes would leave $, ` and \ live, so the copied command
        // would not match what the app actually executed.
        #expect(CommandBuilder.shellQuote("a$b") == "'a$b'")
        #expect(CommandBuilder.shellQuote("`whoami`") == "'`whoami`'")
        #expect(CommandBuilder.shellQuote("with space") == "'with space'")
        #expect(CommandBuilder.shellQuote("semi;colon") == "'semi;colon'")
    }

    @Test("Embedded single quotes are escaped portably")
    func singleQuotesAreEscaped() {
        #expect(CommandBuilder.shellQuote("it's") == #"'it'\''s'"#)
    }

    @Test("An empty token renders as explicit empty quotes")
    func emptyTokenIsQuoted() {
        #expect(CommandBuilder.shellQuote("") == "''")
    }

    @Test("The rendered shell line is derived from the same argv that runs")
    func shellCommandMatchesArgv() {
        var options = DownloadOptions()
        options.input = "https://example.com/s.m3u8?token=a$b"
        options.basic.saveName = "My Episode"
        // Merging off, so this test stays about quoting rather than the default flag.
        options.merge.muxAfterDone = nil

        let argv = CommandBuilder.arguments(for: options)
        let rendered = CommandBuilder.shellCommand(
            executable: "/tmp/N_m3u8DL-RE",
            arguments: argv)

        #expect(
            rendered
                == "/tmp/N_m3u8DL-RE 'https://example.com/s.m3u8?token=a$b' --save-name 'My Episode'"
        )
    }

    // MARK: - Validation

    @Test("Missing input is reported")
    func emptyInputIsInvalid() {
        let issues = CommandBuilder.validate(DownloadOptions())
        #expect(issues.contains { $0.field == .input })
    }

    @Test("Whitespace-only input counts as missing")
    func whitespaceInputIsInvalid() {
        var options = DownloadOptions()
        options.input = "   \n "
        #expect(CommandBuilder.validate(options).contains { $0.field == .input })
    }

    @Test("Valid options produce no issues")
    func validOptionsPass() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.network.threadCount = 8
        options.merge.muxAfterDone = MuxAfterDone(format: .mkv)

        #expect(CommandBuilder.validate(options).isEmpty)
    }

    @Test(
        "Out-of-range numbers are reported",
        arguments: [
            (0, CommandBuilder.Issue.Field.threadCount),
            (-1, CommandBuilder.Issue.Field.threadCount),
        ])
    func invalidThreadCount(value: Int, field: CommandBuilder.Issue.Field) {
        var options = DownloadOptions()
        options.input = "x"
        options.network.threadCount = value

        #expect(CommandBuilder.validate(options).contains { $0.field == field })
    }

    @Test("An invalid mux combination surfaces through validate")
    func invalidMuxIsReported() {
        var options = DownloadOptions()
        options.input = "x"
        options.merge.muxAfterDone = MuxAfterDone(format: .mp4, muxer: .mkvmerge)

        #expect(CommandBuilder.validate(options).contains { $0.field == .mux })
    }

    // MARK: - Interactive prompt avoidance

    @Test("No stream selection is detected as needing one")
    func noSelectionIsNotExplicit() {
        // The engine falls through to an interactive Spectre.Console prompt when
        // AutoSelect, SubOnly and all three keep-filters are unset. That prompt
        // needs a terminal and crashes when stdout is a pipe — reproduced on a real
        // Apple HLS master playlist with 17 streams. The coordinator relies on this
        // flag to avoid that branch.
        #expect(!DownloadOptions().hasExplicitStreamSelection)
    }

    @Test(
        "Each way of selecting streams counts as explicit",
        arguments: [
            "autoSelect", "subtitleOnly", "selectVideo", "selectAudio", "selectSubtitle",
        ]
    )
    func selectionMethodsAreDetected(kind: String) {
        var options = DownloadOptions()
        switch kind {
        case "autoSelect": options.selection.autoSelect = true
        case "subtitleOnly": options.selection.subtitleOnly = true
        case "selectVideo": options.selection.selectVideo = "best"
        case "selectAudio": options.selection.selectAudio = "best"
        case "selectSubtitle": options.selection.selectSubtitle = "all"
        default: Issue.record("unhandled kind \(kind)")
        }
        #expect(options.hasExplicitStreamSelection, "\(kind) was not recognised")
    }

    @Test("An explicit false for autoSelect does not count as a selection")
    func autoSelectFalseIsNotASelection() {
        // Passing --auto-select False takes the engine down the interactive branch
        // just as omitting it does, so it must not be mistaken for a choice.
        var options = DownloadOptions()
        options.selection.autoSelect = false
        #expect(!options.hasExplicitStreamSelection)
    }

    @Test("An empty filter string does not count as a selection")
    func emptyFilterIsNotASelection() {
        // CommandBuilder omits empty strings, so the engine would never see the
        // flag and would show the prompt.
        var options = DownloadOptions()
        options.selection.selectVideo = ""
        options.selection.selectAudio = ""
        #expect(!options.hasExplicitStreamSelection)
    }

    @Test("A drop filter alone does not avoid the prompt")
    func dropFilterIsNotASelection() {
        // The engine's branch checks only the *keep* filters; -dv/-da/-ds do not
        // steer it away from the interactive prompt.
        var options = DownloadOptions()
        options.selection.dropVideo = "res=\"480*\""
        #expect(!options.hasExplicitStreamSelection)
    }

    // MARK: - Helpers

    /// Asserts `flag` appears immediately followed by `value`, which catches
    /// argument-order bugs that a plain `contains` check would miss.
    private func contains(_ argv: [String], flag: String, value: String) -> Bool {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else {
            return false
        }
        return argv[index + 1] == value
    }
}
