import Foundation

/// Turns `DownloadOptions` into engine arguments.
///
/// ## Two outputs, one source of truth
///
/// `arguments(for:)` produces an `argv` array handed straight to `Process`. No
/// shell is involved, so nothing needs quoting and a URL containing `;` or `$()`
/// cannot turn into command execution.
///
/// `shellCommand(...)` renders that same array as a copy-pasteable shell line
/// **for display only**. Because it derives from the argv, the shown command and
/// the executed command can never drift apart.
nonisolated enum CommandBuilder {

    // MARK: - Argument vector

    /// Booleans are passed with an explicit value rather than as bare flags.
    /// The engine's options are plain `Option<bool>`, so `--flag` alone would
    /// also work, but several default to `true` upstream — meaning turning one
    /// *off* requires the explicit form anyway. Always being explicit keeps the
    /// two cases symmetrical and makes the rendered command self-documenting.
    private static func boolToken(_ value: Bool) -> String { value ? "True" : "False" }

    static func arguments(for options: DownloadOptions) -> [String] {
        var argv: [String] = []

        // The positional `input` argument comes first.
        //
        // Trimmed here, not only in the UI: `validate` already judges the input by its
        // trimmed form, so a value padded with whitespace used to pass validation and then
        // reach the engine untrimmed, which rejects it with "Failed to load URL". The
        // Paste button trims, but pasting with the keyboard does not.
        let input = options.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty { argv.append(input) }

        appendBasic(options.basic, to: &argv)
        appendNetwork(options.network, to: &argv)
        appendSelection(options.selection, to: &argv)
        appendMerge(options.merge, to: &argv)
        appendLive(options.live, to: &argv)
        appendAdvanced(options.advanced, to: &argv)

        argv.append(contentsOf: options.extraArguments)
        return argv
    }

    // MARK: Section builders

    private static func appendBasic(_ basic: DownloadOptions.Basic, to argv: inout [String]) {
        argv.append(option: "--save-name", basic.saveName)
        argv.append(option: "--save-dir", basic.saveDirectory.map(OutputLocator.expandingTilde))
        argv.append(option: "--tmp-dir", basic.tempDirectory.map(OutputLocator.expandingTilde))
        argv.append(option: "--save-pattern", basic.savePattern)
    }

    private static func appendNetwork(_ network: DownloadOptions.Network, to argv: inout [String]) {
        // One -H per header. The engine's -H has Arity.OneOrMore with
        // AllowMultipleArgumentsPerToken = false, so each value needs its own flag.
        for header in network.headers where !header.name.isEmpty {
            argv.append("-H")
            argv.append(header.argumentValue)
        }
        argv.append(option: "--thread-count", network.threadCount.map(String.init))
        argv.append(option: "--download-retry-count", network.downloadRetryCount.map(String.init))
        argv.append(option: "--http-request-timeout", network.httpRequestTimeout.map(formatSeconds))
        argv.append(option: "--max-speed", network.maxSpeed)
        argv.append(option: "--custom-proxy", network.customProxy)
        argv.append(option: "--use-system-proxy", network.useSystemProxy.map(boolToken))
    }

    private static func appendSelection(
        _ selection: DownloadOptions.Selection, to argv: inout [String]
    ) {
        argv.append(option: "-sv", selection.selectVideo)
        argv.append(option: "-sa", selection.selectAudio)
        argv.append(option: "-ss", selection.selectSubtitle)
        argv.append(option: "-dv", selection.dropVideo)
        argv.append(option: "-da", selection.dropAudio)
        argv.append(option: "-ds", selection.dropSubtitle)
        argv.append(option: "--custom-range", selection.customRange)
        for keyword in selection.adKeywords where !keyword.isEmpty {
            argv.append("--ad-keyword")
            argv.append(keyword)
        }
        argv.append(option: "--sub-format", selection.subtitleFormat?.rawValue)
        argv.append(option: "--auto-select", selection.autoSelect.map(boolToken))
        argv.append(option: "--sub-only", selection.subtitleOnly.map(boolToken))
        argv.append(option: "--auto-subtitle-fix", selection.autoSubtitleFix.map(boolToken))
    }

    private static func appendMerge(_ merge: DownloadOptions.Merge, to argv: inout [String]) {
        if let mux = merge.muxAfterDone {
            argv.append("-M")
            argv.append(render(mux))
        }
        for importSpec in merge.muxImports where !importSpec.isEmpty {
            argv.append("--mux-import")
            argv.append(importSpec)
        }
        for key in merge.keys where !key.isEmpty {
            argv.append("--key")
            argv.append(key)
        }
        argv.append(option: "--key-text-file", merge.keyTextFile)
        argv.append(option: "--decryption-engine", merge.decryptionEngine?.rawValue)
        argv.append(option: "--decryption-binary-path", merge.decryptionBinaryPath)
        argv.append(option: "--custom-hls-method", merge.customHLSMethod?.rawValue)
        argv.append(option: "--custom-hls-key", merge.customHLSKey)
        argv.append(option: "--custom-hls-iv", merge.customHLSIV)
        argv.append(option: "--skip-merge", merge.skipMerge.map(boolToken))
        argv.append(option: "--binary-merge", merge.binaryMerge.map(boolToken))
        argv.append(
            option: "--mp4-real-time-decryption", merge.mp4RealTimeDecryption.map(boolToken))
        argv.append(
            option: "--use-ffmpeg-concat-demuxer", merge.useFFmpegConcatDemuxer.map(boolToken))
        argv.append(option: "--del-after-done", merge.deleteAfterDone.map(boolToken))
    }

    private static func appendLive(_ live: DownloadOptions.Live, to argv: inout [String]) {
        argv.append(option: "--live-record-limit", live.recordLimit)
        argv.append(option: "--live-wait-time", live.waitTime.map(String.init))
        argv.append(option: "--live-take-count", live.takeCount.map(String.init))
        argv.append(option: "--live-real-time-merge", live.realTimeMerge.map(boolToken))
        argv.append(option: "--live-pipe-mux", live.pipeMux.map(boolToken))
        argv.append(option: "--live-perform-as-vod", live.performAsVOD.map(boolToken))
        argv.append(option: "--live-fix-vtt-by-audio", live.fixVTTByAudio.map(boolToken))
        argv.append(option: "--live-keep-segments", live.keepSegments.map(boolToken))
    }

    private static func appendAdvanced(
        _ advanced: DownloadOptions.Advanced, to argv: inout [String]
    ) {
        argv.append(option: "--log-level", advanced.logLevel?.rawValue)
        argv.append(option: "--log-file-path", advanced.logFilePath)
        argv.append(option: "--ffmpeg-binary-path", advanced.ffmpegBinaryPath)
        argv.append(option: "--urlprocessor-args", advanced.urlProcessorArgs)
        argv.append(option: "--base-url", advanced.baseURL)
        argv.append(option: "--ui-language", advanced.uiLanguage?.rawValue)
        argv.append(option: "--task-start-at", advanced.taskStartAt)
        argv.append(option: "-mt", advanced.concurrentDownload.map(boolToken))
        argv.append(option: "--no-log", advanced.noLog.map(boolToken))
        argv.append(option: "--no-ansi-color", advanced.noAnsiColor.map(boolToken))
        argv.append(option: "--force-ansi-console", advanced.forceAnsiConsole.map(boolToken))
        argv.append(option: "--append-url-params", advanced.appendURLParams.map(boolToken))
        argv.append(option: "--no-date-info", advanced.noDateInfo.map(boolToken))
        argv.append(option: "--disable-update-check", advanced.disableUpdateCheck.map(boolToken))
        argv.append(option: "--skip-download", advanced.skipDownload.map(boolToken))
        argv.append(
            option: "--allow-hls-multi-ext-map", advanced.allowHLSMultiExtMap.map(boolToken))
        argv.append(option: "--check-segments-count", advanced.checkSegmentsCount.map(boolToken))
        argv.append(option: "--write-meta-json", advanced.writeMetaJSON.map(boolToken))
    }

    // MARK: - Mux option rendering

    /// Renders `-M` as the engine's colon-separated `key=value` form. Only
    /// non-default keys are emitted to keep the command readable; `format` is
    /// always included because the engine falls back to parsing the text before
    /// the first `:` as the format, which is easy to get wrong implicitly.
    static func render(_ mux: MuxAfterDone) -> String {
        var parts = ["format=\(mux.format.rawValue)"]
        if mux.muxer != .engineDefault { parts.append("muxer=\(mux.muxer.rawValue)") }
        if let binPath = mux.binPath, !binPath.isEmpty { parts.append("bin_path=\(binPath)") }
        if mux.keep { parts.append("keep=true") }
        if mux.skipSubtitles { parts.append("skip_sub=true") }
        return parts.joined(separator: ":")
    }

    /// `--http-request-timeout` is a `double` upstream. Render whole numbers
    /// without a decimal point so the command reads `100` rather than `100.0`.
    private static func formatSeconds(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15
            ? String(Int(value))
            : String(value)
    }

    // MARK: - Shell rendering (display only)

    /// Renders an executable plus argv as a single copy-pasteable shell line.
    ///
    /// Never used to execute anything — `Process` receives the argv array
    /// directly. This exists so the user can see, copy, and share the exact
    /// equivalent command.
    static func shellCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    static func shellCommand(executable: String, options: DownloadOptions) -> String {
        shellCommand(executable: executable, arguments: arguments(for: options))
    }

    /// POSIX-safe quoting.
    ///
    /// Single quotes are used rather than double quotes because inside double
    /// quotes a shell still expands `$`, backticks and `\`. A URL with a query
    /// string like `?a=$b` would be silently mangled — the copied command would
    /// differ from what the app actually ran.
    static func shellQuote(_ token: String) -> String {
        if token.isEmpty { return "''" }
        let safe = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=@+,")
        if token.unicodeScalars.allSatisfy({ safe.contains($0) }) { return token }
        // Close the quote, emit an escaped literal quote, reopen: '\'' is the
        // only portable way to put a single quote inside single quotes.
        return "'" + token.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Validation

    struct Issue: Equatable, Identifiable {
        enum Field: Equatable {
            case input
            case mux
            case threadCount
            case downloadRetryCount
            case httpRequestTimeout
            case liveTakeCount
        }
        var id: String { "\(field)-\(message)" }
        let field: Field
        let message: String
    }

    /// Problems that would make the engine fail, surfaced before launching it.
    static func validate(_ options: DownloadOptions) -> [Issue] {
        var issues: [Issue] = []

        if options.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                Issue(field: .input, message: "A stream URL or manifest path is required."))
        }
        if let mux = options.merge.muxAfterDone, let message = mux.validationMessage {
            issues.append(Issue(field: .mux, message: message))
        }
        if let threads = options.network.threadCount, threads < 1 {
            issues.append(Issue(field: .threadCount, message: "Thread count must be at least 1."))
        }
        if let retries = options.network.downloadRetryCount, retries < 0 {
            issues.append(
                Issue(field: .downloadRetryCount, message: "Retry count cannot be negative."))
        }
        if let timeout = options.network.httpRequestTimeout, timeout <= 0 {
            issues.append(
                Issue(
                    field: .httpRequestTimeout, message: "Request timeout must be greater than 0."))
        }
        if let take = options.live.takeCount, take < 1 {
            issues.append(
                Issue(field: .liveTakeCount, message: "Live take count must be at least 1."))
        }
        return issues
    }
}

// MARK: - Helpers

extension Array where Element == String {
    /// Appends `flag value` only when `value` is non-nil and non-empty, so an
    /// untouched field never leaks an empty argument into the command.
    ///
    /// Explicitly `nonisolated` because the target builds with
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, which would otherwise isolate
    /// this pure helper to the main actor and make every call from the
    /// nonisolated builder an error under the Swift 6 language mode.
    fileprivate nonisolated mutating func append(option flag: String, _ value: String?) {
        // Surrounding whitespace is never meaningful in these values (names, paths,
        // ranges, filters) and a stray space in a path would silently name a different
        // directory. Whitespace-only counts as unset.
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return }
        append(flag)
        append(value)
    }
}
