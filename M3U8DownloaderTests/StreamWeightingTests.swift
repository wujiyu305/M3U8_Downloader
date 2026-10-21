import Foundation
import Testing

@testable import M3U8Downloader

/// The overall bar must follow the bytes, not the number of tracks.
///
/// The failure being fixed: a video at 800/900 with other tracks still waiting read as
/// "under 10%" overall, because every stream's bar counted equally.
struct StreamWeightingTests {

    // MARK: - Helpers

    private func record(_ message: String, level: EngineOutputParser.Level = .info)
        -> EngineOutputParser.LogRecord
    {
        .init(timestamp: "12:00:00.000", level: level, message: message)
    }

    private func bar(_ description: String, percent: Double) -> EngineOutputParser.Progress {
        .init(
            streamDescription: description, completedSegments: Int(percent),
            totalSegments: 100, percent: percent, retryAttempt: nil, sizeText: "",
            speedText: "", etaText: "")
    }

    /// A job that has announced `estimates` and drawn one bar per `bars` entry.
    private func job(
        announcing estimates: [String], bars: [(String, Double)]
    ) -> DownloadJob {
        var job = DownloadJob(options: DownloadOptions())
        job.noteSelection(record("Selected streams:"))
        for line in estimates { job.noteSelection(record(line)) }
        job.noteSelection(record("Writing meta json", level: .warn))
        for (description, percent) in bars { job.record(bar(description, percent: percent)) }
        return job
    }

    // MARK: - Reading the engine's lines (copied from the real captures)

    @Test("The three kinds of line in the multi-stream capture are read")
    func readsRealLines() {
        let video = StreamEstimate.parse(
            "Vid 640x360 | 800 Kbps | avc1.4d401e | 4 Segments | ~00m16s")
        #expect(
            video
                == StreamEstimate(
                    kind: .video, bitrateKbps: 800, segments: 4, durationSeconds: 16))

        let audio = StreamEstimate.parse("Aud aud | English Audio | en | 3 Segments | ~00m12s")
        #expect(
            audio
                == StreamEstimate(
                    kind: .audio, bitrateKbps: nil, segments: 3, durationSeconds: 12))

        let sub = StreamEstimate.parse("Sub sub | en | English | 1 Segment | ~00m04s")
        #expect(
            sub
                == StreamEstimate(
                    kind: .subtitle, bitrateKbps: nil, segments: 1, durationSeconds: 4))
    }

    @Test("A video line with no bitrate, as in the single-stream capture, is read")
    func readsLineWithoutBitrate() {
        let parsed = StreamEstimate.parse("Vid Kbps | 6 Segments | ~00m24s")
        #expect(parsed?.kind == .video)
        #expect(parsed?.bitrateKbps == nil)
        #expect(parsed?.segments == 6)
        #expect(parsed?.durationSeconds == 24)
    }

    @Test("Durations past an hour are read")
    func readsHours() {
        let parsed = StreamEstimate.parse("Vid 1920x1080 | 6500 Kbps | 900 Segments | ~1h02m03s")
        #expect(parsed?.durationSeconds == 3723)
    }

    @Test("Text that is not a stream line is rejected")
    func rejectsOtherText() {
        for message in [
            "Selected streams:", "Writing meta json", "Video quality looks fine", "Vid", "Aud",
            "Subtitle, webvtt", "NaN: Unknown", "",
        ] {
            #expect(StreamEstimate.parse(message) == nil, "\(message)")
        }
    }

    // MARK: - Which lines count

    @Test("Only the lines after the selection marker are the selection")
    func onlyAfterTheMarker() {
        var job = DownloadJob(options: DownloadOptions())
        // The engine first lists every extracted stream…
        job.noteSelection(record("Vid 640x360 | 800 Kbps | 4 Segments | ~00m16s"))
        job.noteSelection(record("Vid 1920x1080 | 5000 Kbps | 4 Segments | ~00m16s"))
        #expect(job.streamEstimates.isEmpty)

        // …and only then the ones it will download.
        job.noteSelection(record("Selected streams:"))
        job.noteSelection(record("Vid 640x360 | 800 Kbps | 4 Segments | ~00m16s"))
        #expect(job.streamEstimates.count == 1)
    }

    @Test("The list ends at the first line that is not a stream")
    func listEnds() {
        var job = DownloadJob(options: DownloadOptions())
        job.noteSelection(record("Selected streams:"))
        job.noteSelection(record("Vid 640x360 | 800 Kbps | 4 Segments | ~00m16s"))
        job.noteSelection(record("Writing meta json", level: .warn))
        // A later line that merely looks like a stream must not join the selection.
        job.noteSelection(record("Aud aud | English Audio | en | 3 Segments | ~00m12s"))
        #expect(job.streamEstimates.count == 1)
    }

    @Test("A new marker starts a new list, and a reset forgets the old one")
    func markerResets() {
        var job = DownloadJob(options: DownloadOptions())
        job.noteSelection(record("Selected streams:"))
        job.noteSelection(record("Vid 640x360 | 800 Kbps | 4 Segments | ~00m16s"))
        job.noteSelection(record("Selected streams:"))
        #expect(job.streamEstimates.isEmpty)

        job.noteSelection(record("Aud aud | English Audio | en | 3 Segments | ~00m12s"))
        job.resetStreamEstimates()
        #expect(job.streamEstimates.isEmpty)
        // And a reset also ends any selection being read.
        job.noteSelection(record("Aud aud | English Audio | en | 3 Segments | ~00m12s"))
        #expect(job.streamEstimates.isEmpty)
    }

    // MARK: - The bar

    @Test("A video nearly done is not dragged down by fifteen idle tracks")
    func theReportedScenario() throws {
        let video = "Vid 1920x1080 | 8000 Kbps | avc1.640028 | 900 Segments | ~1h00m00s"
        let audio = "Aud English | en | 900 Segments | ~1h00m00s"
        let subtitle = "Sub en | English | 1 Segment | ~1h00m00s"

        var announced = [video]
        var bars: [(String, Double)] = [("Vid 1920x1080 | 8000 Kbps", 89)]
        for number in 1...5 {
            announced.append(audio)
            bars.append(("Aud English \(number) | en", 0))
        }
        for number in 1...10 {
            announced.append(subtitle)
            bars.append(("Sub en \(number) | English", 0))
        }

        let overall = try #require(job(announcing: announced, bars: bars).overallPercent)
        // The old plain average: 89 / 16 = 5.6.
        #expect(overall > 80, "overall was \(overall)")
        #expect(overall < 89)
    }

    @Test("Finishing the video and then the audio moves the bar in proportion to their size")
    func proportionalToSize() throws {
        let announced = [
            "Vid 640x360 | 1000 Kbps | 100 Segments | ~10m00s",
            "Aud aud | English | 100 Segments | ~10m00s",
        ]
        let videoDone = try #require(
            job(announcing: announced, bars: [("Vid 640x360 | 1000 Kbps", 100), ("Aud aud", 0)])
                .overallPercent)
        let allDone = try #require(
            job(announcing: announced, bars: [("Vid 640x360 | 1000 Kbps", 100), ("Aud aud", 100)])
                .overallPercent)

        // 1000 Kbps video against an assumed 128 Kbps audio: 1000 / 1128.
        #expect(abs(videoDone - 100.0 * 1000 / 1128) < 0.01, "video done: \(videoDone)")
        #expect(abs(allDone - 100) < 0.001)
    }

    @Test("Two streams of one kind are weighted by their own announced size, in order")
    func sameKindMatchedByPosition() throws {
        let announced = [
            "Vid 1920x1080 | 8000 Kbps | 100 Segments | ~1h00m00s",
            "Vid 640x360 | 100 Kbps | 100 Segments | ~1h00m00s",
        ]
        let overall = try #require(
            job(
                announcing: announced,
                bars: [("Vid 1920x1080 | 8000 Kbps", 0), ("Vid 640x360 | 100 Kbps", 100)]
            ).overallPercent)
        // Only the small one is done: 100 of 8100 Kbps-hours, not half.
        #expect(abs(overall - 100.0 * 100 / 8100) < 0.01, "overall was \(overall)")
    }

    @Test("An audio bitrate the manifest gives is used, not the assumed one")
    func announcedAudioBitrateIsUsed() throws {
        let announced = [
            "Vid 640x360 | 1000 Kbps | 100 Segments | ~10m00s",
            "Aud 320 Kbps | English | en | 100 Segments | ~10m00s",
        ]
        let overall = try #require(
            job(
                announcing: announced,
                bars: [("Vid 640x360 | 1000 Kbps", 0), ("Aud 320 Kbps", 100)]
            )
            .overallPercent)
        #expect(abs(overall - 100.0 * 320 / 1320) < 0.01, "overall was \(overall)")
    }

    @Test("A stream the engine announced but has not drawn yet counts as unstarted")
    func undrawnStreamCounts() throws {
        let announced = [
            "Vid 640x360 | 1000 Kbps | 100 Segments | ~10m00s",
            "Vid 1280x720 | 1000 Kbps | 100 Segments | ~10m00s",
        ]
        let overall = try #require(
            job(announcing: announced, bars: [("Vid 640x360 | 1000 Kbps", 100)]).overallPercent)
        // One of two equal streams is done; the other is not on screen yet.
        #expect(abs(overall - 50) < 0.001, "overall was \(overall)")
    }

    @Test("Without the selection list the weights fall back to the kind of stream")
    func fallbackByKind() throws {
        var job = DownloadJob(options: DownloadOptions())
        job.record(bar("Vid 1920x1080 | 8000 Kbps", percent: 89))
        for number in 1...5 { job.record(bar("Aud English \(number) | en", percent: 0)) }
        for number in 1...10 { job.record(bar("Sub en \(number) | English", percent: 0)) }

        let overall = try #require(job.overallPercent)
        // A plain average would be 5.6.
        #expect(overall > 60, "overall was \(overall)")
    }

    @Test("A bar with an unrecognised label still counts")
    func unlabelledBar() throws {
        var job = DownloadJob(options: DownloadOptions())
        job.record(bar("", percent: 50))
        let overall = try #require(job.overallPercent)
        #expect(abs(overall - 50) < 0.001)
    }

    @Test("A single stream reads exactly as the engine reports it")
    func singleStreamIsUnchanged() throws {
        let overall = try #require(
            job(announcing: ["Vid Kbps | 6 Segments | ~00m24s"], bars: [("Vid Kbps", 33.33)])
                .overallPercent)
        #expect(abs(overall - 33.33) < 0.0001)
    }

    @Test("No bars means no overall figure")
    func noBars() {
        #expect(DownloadJob(options: DownloadOptions()).overallPercent == nil)
    }

    // MARK: - Weights

    @Test("A video with no bitrate borrows the highest one announced for another video")
    func videoBorrowsBitrate() {
        let known = StreamEstimate(
            kind: .video, bitrateKbps: 5000, segments: nil, durationSeconds: 100)
        let unknown = StreamEstimate(
            kind: .video, bitrateKbps: nil, segments: nil, durationSeconds: 100)
        #expect(unknown.weight(videoFallbackKbps: 5000) == known.weight())
        #expect(unknown.weight() != known.weight())
    }

    @Test("Duration falls back to the segment count, then to a single segment")
    func durationFallbacks() {
        let withSegments = StreamEstimate(
            kind: .audio, bitrateKbps: 100, segments: 10, durationSeconds: nil)
        let withDuration = StreamEstimate(
            kind: .audio, bitrateKbps: 100, segments: nil, durationSeconds: 60)
        #expect(withSegments.weight() == withDuration.weight())

        let nothing = StreamEstimate(
            kind: .audio, bitrateKbps: 100, segments: nil, durationSeconds: nil)
        #expect(nothing.weight() > 0)
    }

    @Test("Video outweighs audio, and audio outweighs subtitles, when nothing else is known")
    func kindOrdering() {
        let video = StreamEstimate.defaultWeight(for: .video)
        let audio = StreamEstimate.defaultWeight(for: .audio)
        let subtitle = StreamEstimate.defaultWeight(for: .subtitle)
        #expect(video > audio)
        #expect(audio > subtitle)
    }

    // MARK: - Against the real captures

    /// Replays a capture through a job the way the coordinator does.
    private func replay(_ fixture: String) throws -> [Double] {
        let text = try EngineOutputParserTests.loadFixture(fixture)
        var job = DownloadJob(options: DownloadOptions())
        var readings: [Double] = []
        for event in EngineOutputParser.events(in: text) {
            switch event {
            case .log(let record): job.noteSelection(record)
            case .progress(let progress):
                job.record(progress)
                if let overall = job.overallPercent { readings.append(overall) }
            }
        }
        return readings
    }

    @Test("The multi-stream capture announces its three streams, not six")
    func realSelection() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-multi-stream")
        var job = DownloadJob(options: DownloadOptions())
        for case .log(let record) in EngineOutputParser.events(in: text) {
            job.noteSelection(record)
        }
        #expect(job.streamEstimates.map(\.kind) == [.video, .audio, .subtitle])
    }

    @Test("Replaying the real multi-stream capture never moves the bar backwards")
    func neverBackwardsOnRealCapture() throws {
        let readings = try replay("engine-stdout-multi-stream")
        #expect(readings.count > 10, "the capture produced \(readings.count) readings")

        var previous = 0.0
        for (position, reading) in readings.enumerated() {
            if reading + 0.0001 < previous {
                Issue.record("went from \(previous) to \(reading) at reading \(position)")
                return
            }
            previous = reading
        }
        #expect(readings.last.map { $0 > 90 } == true, "ended at \(readings.last ?? -1)")
    }

    @Test("In the real capture the bar is already high when the video finishes")
    func videoDominatesRealCapture() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-multi-stream")
        var job = DownloadJob(options: DownloadOptions())
        var atVideoDone: Double?
        for event in EngineOutputParser.events(in: text) {
            switch event {
            case .log(let record): job.noteSelection(record)
            case .progress(let progress):
                job.record(progress)
                let videoPercent = job.streamProgress.first?.percent ?? 0
                if atVideoDone == nil, videoPercent >= 100 { atVideoDone = job.overallPercent }
            }
        }
        let reading = try #require(atVideoDone, "the video never finished in the capture")
        // Video is ~89% of the estimated bytes here. A plain average of three bars gives 33.3.
        #expect(reading > 80, "the bar read \(reading) when the video finished")
    }
}
