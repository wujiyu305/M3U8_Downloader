import Foundation

// How a track is presented in the selection sheet.
//
// Kept apart from `MediaStream.summary` on purpose. `summary` is the engine-flavoured one-line
// description: it is quoted in the "cannot be requested precisely" message and asserted on by
// tests, so reshaping it would change behaviour that is not about presentation. This is the
// structured form the sheet draws from.

extension MediaStream {

    /// A track broken into the pieces the sheet lays out separately: a headline, short tags
    /// worth scanning for, and a quieter line of supporting detail.
    nonisolated struct Presentation: Equatable, Sendable {
        let title: String
        /// Short labels such as `HEVC`, `HDR10` or `Atmos`.
        let tags: [String]
        /// Secondary line, or `nil` when there is nothing further to say.
        let detail: String?
    }

    nonisolated var presentation: Presentation {
        switch kind {
        case .video: return videoPresentation
        case .audio: return audioPresentation
        case .subtitle: return subtitlePresentation
        }
    }

    // MARK: - Video

    private nonisolated var videoPresentation: Presentation {
        var tags: [String] = []
        if let family = Self.codecFamily(of: codecs) { tags.append(family) }
        if let range = Self.rangeTag(of: videoRange, codecs: codecs) { tags.append(range) }

        var detail: [String] = []
        if let bandwidth { detail.append(Self.formatBitrate(bandwidth)) }
        if let frameRate { detail.append("\(String(format: "%g", frameRate)) fps") }
        // The raw string stays: two HEVC renditions at one resolution can differ only in
        // profile and tier (`H150` against `L153`), which the family tag deliberately hides.
        if let codecs { detail.append(codecs) }

        return Presentation(
            title: resolution ?? url,
            tags: tags,
            detail: detail.isEmpty ? nil : detail.joined(separator: " · ")
        )
    }

    /// `avc1` and friends to a name people recognise. Unknown prefixes yield `nil` rather
    /// than a guess; the raw codec string is still shown in the detail line.
    nonisolated static func codecFamily(of codecs: String?) -> String? {
        guard let prefix = codecs?.split(separator: ".").first.map(String.init)?.lowercased()
        else { return nil }
        switch prefix {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "Dolby Vision"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        default: return nil
        }
    }

    /// SDR is the unremarkable default and is left untagged, so a tag means something.
    ///
    /// `PQ` is the transfer function, not a format name. Under a Dolby Vision codec it is
    /// already announced by the family tag, so adding "HDR10" there would be wrong: a
    /// profile 5 Dolby Vision stream is not HDR10-compatible.
    nonisolated static func rangeTag(of range: String?, codecs: String?) -> String? {
        switch range?.uppercased() {
        case "PQ":
            return codecFamily(of: codecs) == "Dolby Vision" ? nil : "HDR10"
        case "HLG": return "HLG"
        default: return nil
        }
    }

    // MARK: - Audio

    private nonisolated var audioPresentation: Presentation {
        var tags: [String] = []
        if let layout = Self.channelLayout(of: channels) { tags.append(layout) }
        if let language, !language.isEmpty { tags.append(language) }

        return Presentation(
            title: name ?? language ?? url,
            tags: tags,
            detail: groupID
        )
    }

    /// The real captures carry `2` and `16/JOC` — the latter being Dolby Atmos, whose
    /// "16" is the bed's channel count and which no one reads as a layout. Everything
    /// else is shown as a plain count: 6 is *usually* 5.1, but nothing here says so.
    nonisolated static func channelLayout(of channels: String?) -> String? {
        guard let channels, !channels.isEmpty else { return nil }
        if channels.uppercased().contains("JOC") { return "Atmos" }
        if channels == "2" { return "Stereo" }
        return "\(channels) ch"
    }

    // MARK: - Subtitles

    private nonisolated var subtitlePresentation: Presentation {
        var tags: [String] = []
        if let language, !language.isEmpty { tags.append(language) }

        return Presentation(
            title: name ?? language ?? url,
            tags: tags,
            detail: groupID
        )
    }

    // MARK: - Formatting

    /// `12626963` to `12.6 Mbps`, and `803000` to `803 Kbps`.
    ///
    /// Decimal units, matching the manifest's and the engine's own: a "Mbps" that meant
    /// 1 048 576 would disagree with the `Kbps` figure printed in the log.
    nonisolated static func formatBitrate(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        return "\(bitsPerSecond / 1000) Kbps"
    }
}
