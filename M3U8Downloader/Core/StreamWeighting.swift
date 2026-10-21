import Foundation

/// How much of a download each stream represents, so the overall bar can be weighted by work
/// rather than by count.
///
/// The engine downloads one stream after another and prints a bar for each. Averaging those
/// bars gave a pending subtitle track the same weight as the hour-long video: with a video
/// at 800/900 and fifteen other tracks waiting, the overall bar read about 5%. What the user
/// is waiting for is bytes, so each stream is weighted by an estimate of its size.
///
/// ## Where the estimate comes from
///
/// Before downloading, the engine logs every selected stream with its segment count and
/// duration, and the bitrate when the manifest has one:
///
/// ```
/// Selected streams:
/// Vid 640x360 | 800 Kbps | avc1.4d401e | 4 Segments | ~00m16s
/// Aud aud | English Audio | en | 3 Segments | ~00m12s
/// Sub sub | en | English | 1 Segment | ~00m04s
/// ```
///
/// (`Fixtures/engine-stdout-multi-stream.txt`.) Size ≈ duration × bitrate. Weights are fixed
/// once that list is read, so the bar only ever moves forward: they are not revised from the
/// sizes the engine reports later, which would make the bar jump when an estimate changed.
nonisolated struct StreamEstimate: Equatable, Sendable {

    enum Kind: String, Sendable {
        case video = "Vid"
        case audio = "Aud"
        case subtitle = "Sub"
    }

    let kind: Kind
    /// From the description, e.g. `800 Kbps`. `nil` when the manifest carries none, which is
    /// usual for audio and always the case for subtitles.
    let bitrateKbps: Int?
    let segments: Int?
    let durationSeconds: Int?

    // MARK: - Reading the engine's line

    /// A stream line from the engine's `Selected streams:` list, or `nil` for any other text.
    ///
    /// Only meaningful straight after that marker: the same lines are also logged for every
    /// *extracted* stream, before selection, and those must not be counted.
    static func parse(_ message: String) -> StreamEstimate? {
        guard message.count > 4, let kind = Kind(rawValue: String(message.prefix(3))),
            message.dropFirst(3).first == " "
        else { return nil }

        return StreamEstimate(
            kind: kind,
            bitrateKbps: firstInteger(in: message, matching: #"(\d+) Kbps"#),
            segments: firstInteger(in: message, matching: #"(\d+) Segments?"#),
            durationSeconds: duration(in: message)
        )
    }

    private static func firstInteger(in text: String, matching pattern: String) -> Int? {
        guard let match = text.firstMatch(of: try! Regex(pattern)),
            let digits = match.output[1].substring
        else { return nil }
        return Int(digits)
    }

    /// `~00m16s`, or `~1h02m03s` once past an hour (`GlobalUtil.FormatTime`).
    private static func duration(in text: String) -> Int? {
        guard let match = text.firstMatch(of: try! Regex(#"~(?:(\d+)h)?(\d+)m(\d+)s"#)) else {
            return nil
        }
        let hours = match.output[1].substring.flatMap { Int($0) } ?? 0
        guard let minutes = match.output[2].substring.flatMap({ Int($0) }),
            let seconds = match.output[3].substring.flatMap({ Int($0) })
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: - Weight

    /// Bitrates assumed when the manifest gives none. Round, deliberately: the weight only
    /// has to be right about *which stream dominates*, and an audio track is two orders of
    /// magnitude below the video whatever its exact rate.
    private static let assumedAudioKbps = 128
    private static let assumedSubtitleKbps = 1
    private static let assumedVideoKbps = 2_000
    /// Seconds per segment when the engine gave no duration. Typical for HLS.
    private static let assumedSegmentSeconds = 6

    /// Relative size of this stream. Only ratios between streams of one job mean anything.
    func weight(videoFallbackKbps: Int? = nil) -> Double {
        let kbps: Int
        switch kind {
        case .video: kbps = bitrateKbps ?? videoFallbackKbps ?? Self.assumedVideoKbps
        case .audio: kbps = bitrateKbps ?? Self.assumedAudioKbps
        case .subtitle: kbps = bitrateKbps ?? Self.assumedSubtitleKbps
        }
        let seconds =
            durationSeconds
            ?? segments.map { $0 * Self.assumedSegmentSeconds }
            ?? Self.assumedSegmentSeconds
        return Double(max(kbps, 1)) * Double(max(seconds, 1))
    }

    /// Weight of a stream about which nothing is known beyond its kind.
    static func defaultWeight(for kind: Kind?) -> Double {
        switch kind {
        case .video, nil: return Double(assumedVideoKbps) * 600
        case .audio: return Double(assumedAudioKbps) * 600
        case .subtitle: return Double(assumedSubtitleKbps) * 600
        }
    }

    /// The kind of a stream from its progress-bar label (`Vid 640x360 | …`).
    static func kind(ofDescription description: String) -> Kind? {
        Kind(rawValue: String(description.prefix(3)))
    }
}
