import Foundation

/// A single selectable track from a parsed manifest.
///
/// Built from the engine's `meta.json`, which it writes before selection when run
/// with `--skip-download True`.
///
/// ## Field values come from `meta.json`, never from the log
///
/// The engine's log renders tracks for humans and those strings are **not** the
/// underlying values. A real example that cost a debugging round: the log prints
/// `Aud 2ch | English Audio | en | 2CH`, but the actual `Channels` field is `2` —
/// so a filter built from the log's `2CH` matched nothing. Always parse
/// `meta.json`.
nonisolated struct MediaStream: Identifiable, Equatable, Sendable {

    enum Kind: String, Sendable, CaseIterable {
        case video
        case audio
        case subtitle

        /// The engine option that selects this kind.
        var selectFlag: String {
            switch self {
            case .video: return "-sv"
            case .audio: return "-sa"
            case .subtitle: return "-ss"
            }
        }
    }

    /// `Url` is unique per track, so it doubles as the identity.
    var id: String { url }

    let kind: Kind
    let url: String

    // Video
    let bandwidth: Int?
    let codecs: String?
    let resolution: String?
    let frameRate: Double?
    let videoRange: String?

    // Audio and subtitle
    let groupID: String?
    let name: String?
    let language: String?
    let channels: String?

    // MARK: - Display

    /// A one-line description in roughly the same order the engine's own listing
    /// uses, so the UI reads familiarly to anyone who has used the CLI.
    var summary: String {
        var parts: [String] = []
        switch kind {
        case .video:
            if let resolution { parts.append(resolution) }
            if let bandwidth { parts.append("\(bandwidth / 1000) Kbps") }
            if let frameRate { parts.append(String(format: "%g", frameRate)) }
            if let codecs { parts.append(codecs) }
            if let videoRange { parts.append(videoRange) }
        case .audio:
            if let name { parts.append(name) }
            if let language { parts.append(language) }
            if let channels { parts.append("\(channels) ch") }
            if let groupID { parts.append(groupID) }
        case .subtitle:
            if let name { parts.append(name) }
            if let language { parts.append(language) }
            if let groupID { parts.append(groupID) }
        }
        return parts.isEmpty ? url : parts.joined(separator: " · ")
    }
}

// MARK: - Catalog

/// The full set of tracks a manifest offers, and the logic for turning a chosen
/// subset back into engine arguments.
nonisolated struct StreamCatalog: Equatable, Sendable {

    let streams: [MediaStream]

    var video: [MediaStream] { streams.filter { $0.kind == .video } }
    var audio: [MediaStream] { streams.filter { $0.kind == .audio } }
    var subtitles: [MediaStream] { streams.filter { $0.kind == .subtitle } }

    var isEmpty: Bool { streams.isEmpty }

    // MARK: - Parsing

    enum ParseError: LocalizedError, Equatable {
        case notFound
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "The engine did not write a stream list (meta.json)."
            case .malformed(let detail):
                return "The engine's stream list could not be read: \(detail)"
            }
        }
    }

    /// Parses the engine's `meta.json`.
    ///
    /// The file is written with a UTF-8 BOM, which `JSONDecoder` rejects, so it is
    /// stripped first.
    static func parse(metaJSON data: Data) throws -> StreamCatalog {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let body = data.starts(with: bom) ? data.dropFirst(bom.count) : data

        guard let raw = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            throw ParseError.malformed("expected a JSON array of stream objects")
        }

        let streams = raw.compactMap(makeStream)
        guard !streams.isEmpty else {
            throw ParseError.malformed("no usable streams in a list of \(raw.count) entries")
        }
        return StreamCatalog(streams: streams)
    }

    private static func makeStream(from object: [String: Any]) -> MediaStream? {
        guard let url = object["Url"] as? String, !url.isEmpty else { return nil }

        // Video entries carry no `MediaType` key at all; the engine calls them
        // "basic streams" and treats anything not audio or subtitle as one.
        let kind: MediaStream.Kind
        switch object["MediaType"] as? String {
        case "AUDIO": kind = .audio
        case "SUBTITLES": kind = .subtitle
        default: kind = .video
        }

        return MediaStream(
            kind: kind,
            url: url,
            bandwidth: object["Bandwidth"] as? Int,
            codecs: object["Codecs"] as? String,
            resolution: object["Resolution"] as? String,
            frameRate: object["FrameRate"] as? Double,
            videoRange: object["VideoRange"] as? String,
            groupID: object["GroupId"] as? String,
            name: object["Name"] as? String,
            language: object["Language"] as? String,
            channels: object["Channels"] as? String
        )
    }

    /// Finds and reads `meta.json` under a directory the engine wrote into.
    ///
    /// The engine nests its output in a timestamped subdirectory, so the file is
    /// searched for rather than assumed at a fixed path.
    static func loadMetaJSON(in directory: URL) throws -> StreamCatalog {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var candidates: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "meta.json" { candidates.append(url) }
        }
        // Newest wins, in case an earlier probe left a file behind.
        let newest = candidates.max {
            let lhs =
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs =
                (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        guard let newest, let data = try? Data(contentsOf: newest) else {
            throw ParseError.notFound
        }
        return try parse(metaJSON: data)
    }
}

// MARK: - Turning a selection back into engine arguments

extension StreamCatalog {

    /// The outcome of expressing a chosen subset as engine filters.
    ///
    /// Not every subset is expressible. The engine takes **one** filter per kind and
    /// ANDs its fields together, so selecting two tracks that differ in two or more
    /// fields creates a cross product: alternating both fields also matches
    /// combinations the user did not pick. Rather than silently downloading the
    /// wrong tracks, that case is reported.
    enum SelectionFilter: Equatable, Sendable {
        case exact(flag: String, value: String)
        /// The subset cannot be expressed; carries the extra tracks the closest
        /// filter would have also matched.
        case inexpressible(kind: MediaStream.Kind, wouldAlsoMatch: [MediaStream])
    }

    /// Builds a filter for every kind that has a selection.
    func filters(for selection: Set<String>) -> [SelectionFilter] {
        MediaStream.Kind.allCases.compactMap { kind in
            let chosen = streams.filter { $0.kind == kind && selection.contains($0.id) }
            guard !chosen.isEmpty else { return nil }
            return filter(kind: kind, chosen: chosen)
        }
    }

    /// Builds one kind's filter, verifying locally that it matches exactly the
    /// chosen tracks and nothing else.
    func filter(kind: MediaStream.Kind, chosen: [MediaStream]) -> SelectionFilter {
        let candidates = streams.filter { $0.kind == kind }
        let clauses = Self.clauses(for: kind, chosen: chosen, amongst: candidates)

        // Simulate the engine's own matching — IsMatch on each field, ANDed — so an
        // unexpressible subset is caught here instead of producing a wrong download.
        let matched = candidates.filter { Self.matches($0, clauses: clauses) }
        let chosenIDs = Set(chosen.map(\.id))
        let extra = matched.filter { !chosenIDs.contains($0.id) }
        guard extra.isEmpty, matched.count == chosen.count else {
            return .inexpressible(kind: kind, wouldAlsoMatch: extra)
        }

        var parts = clauses.map { "\($0.key)=\($0.pattern)" }
        // `for=all` keeps every match; the default `best` would silently narrow a
        // multi-track selection down to one.
        parts.append("for=all")
        return .exact(flag: kind.selectFlag, value: parts.joined(separator: ":"))
    }

    // MARK: Clause construction

    struct Clause: Equatable {
        let key: String
        let pattern: String
        /// The field this clause tests, used by the local simulation.
        let field: (MediaStream) -> String?

        static func == (lhs: Clause, rhs: Clause) -> Bool {
            lhs.key == rhs.key && lhs.pattern == rhs.pattern
        }
    }

    /// Which fields identify a track of each kind.
    ///
    /// Deliberately avoids `url=`: a URL contains `:` — which
    /// `ComplexParamParser` treats as the end of a value unless escaped, and whose
    /// escape handling then strips other backslashes — and it can contain
    /// `key=value` query parameters that the parser would mistake for filter keys
    /// such as `res=`. The fields below are colon-free in practice.
    ///
    /// `frame` is also avoided: the engine matches it against .NET's default
    /// `Double` formatting, which is not something to depend on from Swift.
    private static func identifyingFields(
        for kind: MediaStream.Kind
    ) -> [(key: String, field: (MediaStream) -> String?)] {
        switch kind {
        case .video:
            return [
                ("res", { $0.resolution }),
                ("codecs", { $0.codecs }),
                ("range", { $0.videoRange }),
            ]
        case .audio:
            return [
                ("id", { $0.groupID }),
                ("name", { $0.name }),
                ("lang", { $0.language }),
                ("channel", { $0.channels }),
            ]
        case .subtitle:
            return [
                ("id", { $0.groupID }),
                ("name", { $0.name }),
                ("lang", { $0.language }),
            ]
        }
    }

    private static func clauses(
        for kind: MediaStream.Kind,
        chosen: [MediaStream],
        amongst candidates: [MediaStream]
    ) -> [Clause] {
        var clauses: [Clause] = []

        for (key, field) in identifyingFields(for: kind) {
            let values = chosen.map(field)
            // A field absent from any chosen track cannot be pinned: the engine
            // drops tracks whose field is nil before testing the regex, so
            // requiring it would exclude the very track the user picked.
            guard values.allSatisfy({ $0 != nil }) else { continue }
            let present = values.compactMap { $0 }

            // A value containing a colon would be truncated by the engine's
            // parser, so such a field is skipped rather than silently mangled.
            guard present.allSatisfy({ !$0.contains(":") }) else { continue }

            let distinct = Set(present)
            // Nothing to constrain if every candidate already shares this value.
            let candidateValues = Set(candidates.compactMap(field))
            if candidateValues.count <= 1, distinct.count <= 1 { continue }

            let alternatives = distinct.sorted().map(escapeForRegex)
            let pattern =
                alternatives.count == 1
                ? "^\(alternatives[0])$"
                : "^(\(alternatives.joined(separator: "|")))$"
            clauses.append(Clause(key: key, pattern: pattern, field: field))
        }

        // Bandwidth pins video tracks that are otherwise identical. Expressed as a
        // window because the engine multiplies bwMin/bwMax by 1000 and compares
        // with >= and <=.
        if kind == .video, chosen.count == 1, let bandwidth = chosen[0].bandwidth {
            let kbps = bandwidth / 1000
            clauses.append(Clause(key: "bwMin", pattern: "\(kbps)", field: { _ in nil }))
            clauses.append(Clause(key: "bwMax", pattern: "\(kbps + 1)", field: { _ in nil }))
        }
        return clauses
    }

    /// Mirrors the engine's matching: every clause's regex must find a match in the
    /// corresponding field, and a nil field never matches.
    private static func matches(_ stream: MediaStream, clauses: [Clause]) -> Bool {
        for clause in clauses {
            switch clause.key {
            case "bwMin":
                guard let bandwidth = stream.bandwidth,
                    let kbps = Int(clause.pattern), bandwidth >= kbps * 1000
                else { return false }
            case "bwMax":
                guard let bandwidth = stream.bandwidth,
                    let kbps = Int(clause.pattern), bandwidth <= kbps * 1000
                else { return false }
            default:
                guard let value = clause.field(stream),
                    let regex = try? NSRegularExpression(pattern: clause.pattern),
                    regex.firstMatch(
                        in: value,
                        range: NSRange(value.startIndex..., in: value)
                    ) != nil
                else { return false }
            }
        }
        return true
    }

    /// Escapes regex metacharacters.
    ///
    /// Colons are never escaped here — a value containing one is rejected earlier,
    /// because the engine's `ComplexParamParser` both truncates at an unescaped
    /// colon and strips every accumulated backslash when it meets an escaped one,
    /// which would corrupt the other escapes in the same pattern.
    static func escapeForRegex(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if "\\^$.|?*+()[]{}".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
