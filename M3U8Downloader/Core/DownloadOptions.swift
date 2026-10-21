import Foundation

// MARK: - Engine enums
//
// These mirror the enums in the pinned N_m3u8DL-RE submodule exactly, because
// the values are passed to the engine as literal argument strings. Sources:
//   src/N_m3u8DL-RE/Enum/SubtitleFormat.cs
//   src/N_m3u8DL-RE/Enum/DecryptEngine.cs
//   src/N_m3u8DL-RE/Enum/MuxFormat.cs
//   src/N_m3u8DL-RE.Common/Log/LogLevel.cs
//   src/N_m3u8DL-RE.Common/Enum/EncryptMethod.cs
// If the submodule is bumped, re-check these against the source.

nonisolated enum SubtitleFormat: String, CaseIterable, Codable, Sendable {
    case vtt = "VTT"
    case srt = "SRT"
    /// Engine default (`--sub-format`).
    static let engineDefault: SubtitleFormat = .srt
}

nonisolated enum DecryptEngine: String, CaseIterable, Codable, Sendable {
    case mp4decrypt = "MP4DECRYPT"
    case shakaPackager = "SHAKA_PACKAGER"
    case ffmpeg = "FFMPEG"
    /// Engine default (`--decryption-engine`).
    static let engineDefault: DecryptEngine = .mp4decrypt
}

nonisolated enum LogLevel: String, CaseIterable, Codable, Sendable {
    case off = "OFF"
    case error = "ERROR"
    case warn = "WARN"
    case info = "INFO"
    case debug = "DEBUG"
    /// Engine default (`--log-level`).
    static let engineDefault: LogLevel = .info
}

nonisolated enum MuxFormat: String, CaseIterable, Codable, Sendable {
    case mp4 = "MP4"
    case mkv = "MKV"
    case ts = "TS"
}

nonisolated enum Muxer: String, CaseIterable, Codable, Sendable {
    case ffmpeg
    case mkvmerge
    /// Engine default when `muxer=` is omitted from `-M`.
    static let engineDefault: Muxer = .ffmpeg
}

nonisolated enum EncryptMethod: String, CaseIterable, Codable, Sendable {
    case none = "NONE"
    case aes128 = "AES_128"
    case aes128ECB = "AES_128_ECB"
    case sampleAES = "SAMPLE_AES"
    case sampleAESCTR = "SAMPLE_AES_CTR"
    case cenc = "CENC"
    case chacha20 = "CHACHA20"
    case unknown = "UNKNOWN"
}

nonisolated enum UILanguage: String, CaseIterable, Codable, Sendable {
    case enUS = "en-US"
    case zhCN = "zh-CN"
    case zhTW = "zh-TW"
}

// MARK: - Mux options

/// Value of the engine's `-M` / `--mux-after-done` option.
///
/// Rendered as a colon-separated `key=value` list, e.g. `format=mkv:muxer=ffmpeg`.
nonisolated struct MuxAfterDone: Equatable, Codable, Sendable {
    var format: MuxFormat = .mp4
    var muxer: Muxer = .engineDefault
    /// Path to the muxer binary; `nil` means let the engine decide ("auto").
    var binPath: String?
    /// Keep the pre-mux files instead of deleting them.
    var keep: Bool = false
    /// Exclude subtitles from the muxed output.
    var skipSubtitles: Bool = false

    /// mkvmerge cannot write MP4. The engine rejects this combination too, but
    /// its check compares the raw `format` string against lowercase `"mp4"`
    /// while parsing uppercases it — so `format=MP4:muxer=mkvmerge` slips past
    /// the engine's guard and fails later, deeper in the run. This check is
    /// deliberately case-insensitive so the UI can refuse it up front.
    var isValid: Bool { !(muxer == .mkvmerge && format == .mp4) }

    var validationMessage: String? {
        isValid ? nil : "mkvmerge cannot produce MP4. Choose MKV, or switch the muxer to ffmpeg."
    }
}

// MARK: - Download options

/// Everything the user can configure for one download.
///
/// Every field that maps to an engine option with a default is `Optional`, and
/// `CommandBuilder` emits an argument **only when the value is non-nil**. This
/// avoids comparing against hardcoded defaults, which would be wrong for
/// `--thread-count`: its engine default is `Environment.ProcessorCount`, so it
/// varies by machine and cannot be baked into a constant.
nonisolated struct DownloadOptions: Equatable, Codable, Sendable {

    /// The stream URL or local manifest path. Required positional argument.
    var input: String = ""

    var basic = Basic()
    var network = Network()
    var selection = Selection()
    var merge = Merge()
    var live = Live()
    var advanced = Advanced()

    /// Extra raw arguments appended verbatim, as an escape hatch for engine
    /// options this model does not cover yet.
    var extraArguments: [String] = []

    /// Whether the engine will pick streams without asking.
    ///
    /// Mirrors the branch order in the engine's `Program.DoWorkAsync`: it takes
    /// `AutoSelect`, then `SubOnly`, then any of the three keep-filters, and
    /// **otherwise shows an interactive prompt**. That prompt requires a terminal
    /// and crashes when stdout is a pipe, so a GUI must never leave all four
    /// unset. `DownloadCoordinator` consults this before launching.
    ///
    /// Re-check this against the submodule if it is bumped: an added branch here
    /// would make the app apply auto-select where the engine no longer needs it.
    var hasExplicitStreamSelection: Bool {
        if selection.autoSelect == true { return true }
        if selection.subtitleOnly == true { return true }
        return [selection.selectVideo, selection.selectAudio, selection.selectSubtitle]
            .contains { !($0 ?? "").isEmpty }
    }

    // MARK: Basic

    struct Basic: Equatable, Codable, Sendable {
        var saveName: String?
        var saveDirectory: String?
        var tempDirectory: String?
        var savePattern: String?
    }

    // MARK: Network

    struct Network: Equatable, Codable, Sendable {
        /// Request headers as ordered name/value pairs; each becomes one `-H`.
        /// Cookie and User-Agent are just headers, so they live here too rather
        /// than as special cases.
        var headers: [Header] = []
        /// `nil` keeps the engine default of `Environment.ProcessorCount`.
        var threadCount: Int?
        /// `nil` keeps the engine default of 3.
        var downloadRetryCount: Int?
        /// Seconds. `nil` keeps the engine default of 100.
        var httpRequestTimeout: Double?
        /// Speed cap as the engine's own string form, e.g. `15M`, `500K`.
        var maxSpeed: String?
        var customProxy: String?
        /// `nil` keeps the engine default of `true`.
        var useSystemProxy: Bool?

        struct Header: Equatable, Codable, Sendable, Identifiable {
            var id = UUID()
            var name: String
            var value: String

            init(id: UUID = UUID(), name: String, value: String) {
                self.id = id
                self.name = name
                self.value = value
            }

            /// The engine expects a single `Name: value` token per `-H`.
            var argumentValue: String { "\(name): \(value)" }
        }
    }

    // MARK: Track selection and filtering

    struct Selection: Equatable, Codable, Sendable {
        var selectVideo: String?
        var selectAudio: String?
        var selectSubtitle: String?
        var dropVideo: String?
        var dropAudio: String?
        var dropSubtitle: String?
        var customRange: String?
        var adKeywords: [String] = []
        /// `nil` keeps the engine default of `SRT`.
        var subtitleFormat: SubtitleFormat?
        /// `nil` keeps the engine default of `false`.
        var autoSelect: Bool?
        /// `nil` keeps the engine default of `false`.
        var subtitleOnly: Bool?
        /// `nil` keeps the engine default of `true`.
        var autoSubtitleFix: Bool?
    }

    // MARK: Merging and decryption

    struct Merge: Equatable, Codable, Sendable {
        /// `nil` means do not pass `-M`, leaving the tracks as separate files.
        ///
        /// **Defaults to enabled**, unlike the engine, which merges only when asked.
        /// One playable file is what someone downloading a video almost always
        /// wants; the loose tracks a bare download leaves behind are a surprise
        /// rather than a feature. Turning this off is a deliberate choice and is
        /// then respected silently — the app does not ask again afterwards.
        ///
        /// MP4 is the default container. Measured: the engine converts SRT
        /// subtitles to `mov_text` for MP4, so a stream with subtitles still yields
        /// one file carrying video, audio and subtitle tracks rather than failing.
        var muxAfterDone: MuxAfterDone? = MuxAfterDone()
        var muxImports: [String] = []
        var keys: [String] = []
        var keyTextFile: String?
        /// `nil` keeps the engine default of `MP4DECRYPT`.
        var decryptionEngine: DecryptEngine?
        var decryptionBinaryPath: String?
        var customHLSMethod: EncryptMethod?
        var customHLSKey: String?
        var customHLSIV: String?
        /// `nil` keeps the engine default of `false`.
        var skipMerge: Bool?
        /// `nil` keeps the engine default of `false`.
        var binaryMerge: Bool?
        /// `nil` keeps the engine default of `false`.
        var mp4RealTimeDecryption: Bool?
        /// `nil` keeps the engine default of `false`.
        var useFFmpegConcatDemuxer: Bool?
        /// `nil` keeps the engine default of `true`.
        var deleteAfterDone: Bool?
    }

    // MARK: Live streams

    struct Live: Equatable, Codable, Sendable {
        /// `HH:mm:ss`.
        var recordLimit: String?
        /// Seconds.
        var waitTime: Int?
        /// `nil` keeps the engine default of 16.
        var takeCount: Int?
        /// `nil` keeps the engine default of `false`.
        var realTimeMerge: Bool?
        /// `nil` keeps the engine default of `false`.
        var pipeMux: Bool?
        /// `nil` keeps the engine default of `false`.
        var performAsVOD: Bool?
        /// `nil` keeps the engine default of `false`.
        var fixVTTByAudio: Bool?
        /// `nil` keeps the engine default of `true`.
        var keepSegments: Bool?
    }

    // MARK: Advanced

    struct Advanced: Equatable, Codable, Sendable {
        /// `nil` keeps the engine default of `INFO`.
        var logLevel: LogLevel?
        var logFilePath: String?
        /// Overrides which ffmpeg the *engine* uses. The app fills this in from
        /// `ToolLocator` so the engine and the app agree on one binary.
        var ffmpegBinaryPath: String?
        var urlProcessorArgs: String?
        var baseURL: String?
        var uiLanguage: UILanguage?
        /// `yyyyMMddHHmmss`.
        var taskStartAt: String?
        /// `-mt`. `nil` keeps the engine default of `false`.
        var concurrentDownload: Bool?
        /// `nil` keeps the engine default of `false`.
        var noLog: Bool?
        /// `nil` keeps the engine default of `false`.
        var noAnsiColor: Bool?
        /// `nil` keeps the engine default of `false`.
        var forceAnsiConsole: Bool?
        /// `nil` keeps the engine default of `false`.
        var appendURLParams: Bool?
        /// `nil` keeps the engine default of `false`.
        var noDateInfo: Bool?
        /// `nil` keeps the engine default of `false`.
        var disableUpdateCheck: Bool?
        /// `nil` keeps the engine default of `false`.
        var skipDownload: Bool?
        /// `nil` keeps the engine default of `false`.
        var allowHLSMultiExtMap: Bool?
        /// `nil` keeps the engine default of `true`.
        var checkSegmentsCount: Bool?
        /// `nil` keeps the engine default of `true`.
        var writeMetaJSON: Bool?
    }
}
