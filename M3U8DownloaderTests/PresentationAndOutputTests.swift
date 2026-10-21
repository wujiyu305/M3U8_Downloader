import Foundation
import Testing

@testable import M3U8Downloader

/// Track presentation, save-name recognition, output location and the pre-launch option
/// tweaks. Literals for the real engine's output come from the captured fixtures where one
/// exists; hand-written values are used only for shapes the captures do not contain.

// MARK: - Track presentation

struct MediaStreamPresentationTests {

    private func stream(
        kind: MediaStream.Kind,
        url: String = "u",
        bandwidth: Int? = nil,
        codecs: String? = nil,
        resolution: String? = nil,
        frameRate: Double? = nil,
        videoRange: String? = nil,
        groupID: String? = nil,
        name: String? = nil,
        language: String? = nil,
        channels: String? = nil
    ) -> MediaStream {
        MediaStream(
            kind: kind, url: url, bandwidth: bandwidth, codecs: codecs, resolution: resolution,
            frameRate: frameRate, videoRange: videoRange, groupID: groupID, name: name,
            language: language, channels: channels)
    }

    @Test("Codec prefixes map to the names people recognise")
    func codecFamilies() {
        #expect(MediaStream.codecFamily(of: "avc1.640028") == "H.264")
        #expect(MediaStream.codecFamily(of: "hvc1.2.20000000.H150.B0") == "HEVC")
        #expect(MediaStream.codecFamily(of: "hev1.1.6.L93.B0") == "HEVC")
        #expect(MediaStream.codecFamily(of: "dvh1.05.06") == "Dolby Vision")
        #expect(MediaStream.codecFamily(of: "av01.0.08M.08") == "AV1")
        #expect(MediaStream.codecFamily(of: "vp09.00.10.08") == "VP9")
    }

    @Test("An unknown or absent codec yields no family rather than a guess")
    func unknownCodec() {
        #expect(MediaStream.codecFamily(of: "zzzz.1") == nil)
        #expect(MediaStream.codecFamily(of: nil) == nil)
        #expect(MediaStream.codecFamily(of: "") == nil)
    }

    @Test("PQ is HDR10, except under Dolby Vision where it is not HDR10-compatible")
    func rangeTags() {
        #expect(MediaStream.rangeTag(of: "PQ", codecs: "hvc1.2.4.L153") == "HDR10")
        #expect(MediaStream.rangeTag(of: "PQ", codecs: "dvh1.05.06") == nil)
        #expect(MediaStream.rangeTag(of: "HLG", codecs: "hvc1.2.4.L153") == "HLG")
        #expect(MediaStream.rangeTag(of: "SDR", codecs: "avc1.640028") == nil)
        #expect(MediaStream.rangeTag(of: nil, codecs: nil) == nil)
    }

    @Test("Channel layouts: stereo, Atmos, and a plain count for anything else")
    func channelLayouts() {
        #expect(MediaStream.channelLayout(of: "2") == "Stereo")
        #expect(MediaStream.channelLayout(of: "16/JOC") == "Atmos")
        #expect(MediaStream.channelLayout(of: "6") == "6 ch")
        #expect(MediaStream.channelLayout(of: "") == nil)
        #expect(MediaStream.channelLayout(of: nil) == nil)
    }

    @Test("Bitrates use decimal units and switch at one megabit")
    func bitrates() {
        #expect(MediaStream.formatBitrate(12_626_963) == "12.6 Mbps")
        #expect(MediaStream.formatBitrate(1_000_000) == "1.0 Mbps")
        #expect(MediaStream.formatBitrate(999_999) == "999 Kbps")
        #expect(MediaStream.formatBitrate(803_000) == "803 Kbps")
    }

    @Test("The top video rendition in the real capture reads as intended")
    func realTopVideo() throws {
        let catalog = try StreamCatalogTests.loadCatalog()
        let top = try #require(catalog.video.max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })

        #expect(top.presentation.title == "3840x2160")
        #expect(top.presentation.tags == ["HEVC"])
        let detail = try #require(top.presentation.detail)
        #expect(detail.hasPrefix("12.6 Mbps"))
        #expect(detail.contains("hvc1.2.20000000.H150.B0"))
    }

    @Test("A video with nothing known falls back to its URL and has no detail")
    func bareVideo() {
        let presentation = stream(kind: .video, url: "https://x/v.m3u8").presentation
        #expect(presentation.title == "https://x/v.m3u8")
        #expect(presentation.tags.isEmpty)
        #expect(presentation.detail == nil)
    }

    @Test("Frame rate is printed without trailing zeros")
    func frameRateFormatting() {
        let integral = stream(kind: .video, frameRate: 30).presentation.detail
        let fractional = stream(kind: .video, frameRate: 29.97).presentation.detail
        #expect(integral == "30 fps")
        #expect(fractional == "29.97 fps")
    }

    @Test("Audio shows layout and language as tags and the group as detail")
    func audioPresentation() {
        let presentation = stream(
            kind: .audio, groupID: "audio-atmos", name: "English Audio", language: "en",
            channels: "16/JOC"
        ).presentation

        #expect(presentation.title == "English Audio")
        #expect(presentation.tags == ["Atmos", "en"])
        #expect(presentation.detail == "audio-atmos")
    }

    @Test("A subtitle with no name is titled by its language")
    func subtitleTitle() {
        let presentation = stream(kind: .subtitle, language: "fr").presentation
        #expect(presentation.title == "fr")
        #expect(presentation.tags == ["fr"])
    }
}

// MARK: - Save name

struct SaveNameParsingTests {

    private func record(_ level: EngineOutputParser.Level, _ message: String)
        -> EngineOutputParser.LogRecord
    {
        .init(timestamp: "10:24:55.718", level: level, message: message)
    }

    @Test("The save name is read from the engine's English line")
    func readsSaveName() {
        let name = EngineOutputParser.saveName(in: record(.info, "Save Name: Episode 1"))
        #expect(name == "Episode 1")
    }

    @Test("A localised line is not recognised, which is why the language is pinned")
    func ignoresChinesePrefix() {
        #expect(EngineOutputParser.saveName(in: record(.info, "保存名称: Episode 1")) == nil)
    }

    @Test("Other messages, other levels and empty names yield nothing")
    func rejectsOthers() {
        #expect(EngineOutputParser.saveName(in: record(.info, "Loading url: x")) == nil)
        #expect(EngineOutputParser.saveName(in: record(.warn, "Save Name: A")) == nil)
        #expect(EngineOutputParser.saveName(in: record(.info, "Save Name:    ")) == nil)
    }

    @Test("The real captures yield their save names, with the glued-on timestamp excluded")
    func foundInCaptures() throws {
        // `Save Name: probe210:24:55.721 INFO : …` — the next record's timestamp is glued on
        // with no newline, so the name is `probe2`, not `probe210`.
        let expected = [
            "engine-stdout-failed-download": "probe2",
            "engine-stdout-failed-verdict": "trunc",
            "engine-stdout-progress": "cap",
            "engine-stdout-multi-stream": "multi",
        ]
        for (fixture, name) in expected {
            let text = try EngineOutputParserTests.loadFixture(fixture)
            let found = EngineOutputParser.logRecords(in: text).compactMap {
                EngineOutputParser.saveName(in: $0)
            }
            #expect(found.first == name, "\(fixture)")
        }
    }
}

// MARK: - Output location

struct OutputLocatorTests {

    /// A fresh scratch directory, removed by the caller.
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ name: String, in directory: URL, modified: Date) throws {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test("An explicit save directory is used as given")
    func explicitDirectory() {
        #expect(OutputLocator.directory(saveDirectory: "/tmp/out")?.path == "/tmp/out")
    }

    @Test("No save directory falls back to Downloads, never the current directory")
    func defaultDirectory() {
        let expected = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
        #expect(OutputLocator.directory(saveDirectory: nil) == expected)
        #expect(OutputLocator.directory(saveDirectory: "") == expected)
    }

    @Test("Matches by name prefix and by time, returning every sibling output")
    func prefixAndTime() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()

        try touch("Show.mp4", in: dir, modified: start)
        try touch("Show.en.srt", in: dir, modified: start)
        try touch("Other.mp4", in: dir, modified: start)
        try touch("Show.old.mp4", in: dir, modified: start.addingTimeInterval(-3600))

        let names = OutputLocator.files(in: dir, namedLike: "Show", modifiedSince: start)
            .map(\.lastPathComponent)
        #expect(names == ["Show.en.srt", "Show.mp4"])
    }

    @Test("A file just inside the slack window counts; one outside does not")
    func slackWindow() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()

        try touch("Show.a.mp4", in: dir, modified: start.addingTimeInterval(-1))
        try touch("Show.b.mp4", in: dir, modified: start.addingTimeInterval(-10))

        let names = OutputLocator.files(in: dir, namedLike: "Show", modifiedSince: start)
            .map(\.lastPathComponent)
        #expect(names == ["Show.a.mp4"])
    }

    @Test("A directory sharing the save name is skipped")
    func skipsDirectories() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Show"), withIntermediateDirectories: false)

        let found = OutputLocator.files(in: dir, namedLike: "Show", modifiedSince: Date())
        #expect(found.isEmpty)
    }

    @Test("An empty save name matches nothing instead of everything")
    func emptyName() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch("Show.mp4", in: dir, modified: Date())

        #expect(OutputLocator.files(in: dir, namedLike: "", modifiedSince: Date()).isEmpty)
    }

    @Test("A missing directory yields nothing rather than throwing")
    func missingDirectory() {
        let gone = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(OutputLocator.files(in: gone, namedLike: "a", modifiedSince: Date()).isEmpty)
    }
}

// MARK: - Job output

struct DownloadJobOutputTests {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("job-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A download writes into its chosen save directory")
    func downloadDirectory() {
        var options = DownloadOptions()
        options.basic.saveDirectory = "/tmp/chosen"
        #expect(DownloadJob(options: options).outputDirectory?.path == "/tmp/chosen")
    }

    @Test("A metadata job's directory is the parent of its output file")
    func metadataDirectory() {
        var metadata = MetadataOptions()
        metadata.outputPath = "/tmp/out/final.mp4"
        #expect(DownloadJob(metadata: metadata).outputDirectory?.path == "/tmp/out")
    }

    @Test("A metadata job with no output path has no directory")
    func metadataWithoutOutput() {
        #expect(DownloadJob(metadata: MetadataOptions()).outputDirectory == nil)
    }

    @Test("A metadata job reveals exactly its output, and only if it exists")
    func metadataFiles() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("final.mp4")

        var metadata = MetadataOptions()
        metadata.outputPath = file.path
        let job = DownloadJob(metadata: metadata)

        #expect(job.outputFiles().isEmpty)
        try Data("x".utf8).write(to: file)
        #expect(job.outputFiles() == [file])
    }

    @Test("A download prefers the name the engine reported over the one requested")
    func resolvedNameWins() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("Reported.mp4"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("Requested.mp4"))

        var options = DownloadOptions()
        options.basic.saveDirectory = dir.path
        options.basic.saveName = "Requested"
        var job = DownloadJob(options: options)
        job.startedAt = Date()
        job.resolvedSaveName = "Reported"

        #expect(job.outputFiles().map(\.lastPathComponent) == ["Reported.mp4"])
    }

    @Test("Without a start time or a name nothing is guessed")
    func nothingGuessed() throws {
        var options = DownloadOptions()
        options.basic.saveDirectory = try scratch().path
        #expect(DownloadJob(options: options).outputFiles().isEmpty)
    }
}

// MARK: - Pre-launch options

@MainActor
struct PreparedOptionsTests {

    @Test("The UI language is pinned to English when unset")
    func pinsLanguage() {
        let prepared = DownloadCoordinator.prepared(DownloadOptions(), ffmpegPath: nil)
        #expect(prepared.advanced.uiLanguage == .enUS)
    }

    @Test("An explicit UI language is respected")
    func respectsLanguage() {
        var options = DownloadOptions()
        options.advanced.uiLanguage = .zhCN
        let prepared = DownloadCoordinator.prepared(options, ffmpegPath: nil)
        #expect(prepared.advanced.uiLanguage == .zhCN)
    }

    @Test("ffmpeg and colour defaults are filled, and explicit values kept")
    func otherDefaults() {
        let filled = DownloadCoordinator.prepared(DownloadOptions(), ffmpegPath: "/opt/ff")
        #expect(filled.advanced.ffmpegBinaryPath == "/opt/ff")
        #expect(filled.advanced.noAnsiColor == true)

        var options = DownloadOptions()
        options.advanced.ffmpegBinaryPath = "/mine/ff"
        options.advanced.noAnsiColor = false
        let kept = DownloadCoordinator.prepared(options, ffmpegPath: "/opt/ff")
        #expect(kept.advanced.ffmpegBinaryPath == "/mine/ff")
        #expect(kept.advanced.noAnsiColor == false)
    }
}

// MARK: - URL field

struct StreamURLFieldTests {

    @Test("Pasted whitespace and newlines are trimmed")
    func trims() {
        #expect(StreamURLField.cleaned("  https://a/b.m3u8\n") == "https://a/b.m3u8")
        #expect(StreamURLField.cleaned("\t\n") == "")
    }

    @Test("Interior spaces are left alone")
    func keepsInterior() {
        #expect(StreamURLField.cleaned("/Users/me/My Show.m3u8 ") == "/Users/me/My Show.m3u8")
    }
}
