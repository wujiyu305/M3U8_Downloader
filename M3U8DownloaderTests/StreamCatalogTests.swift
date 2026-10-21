import Foundation
import Testing

@testable import M3U8Downloader

/// Tests for parsing the engine's stream list and turning a selection back into
/// engine filters.
///
/// The fixture `meta-apple-17-streams.json` is a byte-for-byte capture of what the
/// engine wrote for a real Apple HLS master playlist: 12 video, 4 audio, 1 subtitle,
/// complete with its UTF-8 BOM. Hand-written JSON is used only for edge cases the
/// capture does not contain.
struct StreamCatalogTests {

    static func loadCatalog() throws -> StreamCatalog {
        let data = try EngineOutputParserTests.loadFixtureData("meta-apple-17-streams")
        return try StreamCatalog.parse(metaJSON: data)
    }

    // MARK: - Parsing the real capture

    @Test("The real capture parses into the counts the engine reported")
    func realCaptureCounts() throws {
        let catalog = try Self.loadCatalog()

        // The engine logged "17 streams, with 12 basic streams, 4 audio streams,
        // 1 subtitle streams" for this manifest.
        #expect(catalog.streams.count == 17)
        #expect(catalog.video.count == 12)
        #expect(catalog.audio.count == 4)
        #expect(catalog.subtitles.count == 1)
    }

    @Test("A UTF-8 BOM does not prevent parsing")
    func bomIsStripped() throws {
        // The engine writes meta.json with a BOM, which JSONDecoder rejects.
        let raw = try EngineOutputParserTests.loadFixtureData("meta-apple-17-streams")
        #expect(raw.starts(with: Data([0xEF, 0xBB, 0xBF])), "fixture lost its BOM")
        #expect(throws: Never.self) { _ = try StreamCatalog.parse(metaJSON: raw) }
    }

    @Test("Video tracks are recognised even though they carry no MediaType")
    func videoHasNoMediaType() throws {
        let catalog = try Self.loadCatalog()
        let top = try #require(catalog.video.max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })

        #expect(top.resolution == "3840x2160")
        #expect(top.codecs == "hvc1.2.20000000.H150.B0")
        #expect(top.videoRange == "SDR")
        #expect(top.bandwidth == 12_626_963)
    }

    @Test("Channels comes from the field, not the log's rendering")
    func channelsIsTheRawField() throws {
        // The engine's log prints "2CH" for this track while the field is "2".
        // Building a filter from the log text matched nothing — the bug this test
        // exists to prevent.
        let catalog = try Self.loadCatalog()
        let twoChannel = catalog.audio.filter { $0.groupID == "2ch" }

        #expect(twoChannel.count == 2)
        #expect(twoChannel.allSatisfy { $0.channels == "2" }, "expected raw '2', not '2CH'")
        #expect(catalog.audio.contains { $0.channels == "16/JOC" })
    }

    @Test("Malformed input throws rather than yielding an empty catalog")
    func malformedThrows() {
        #expect(throws: StreamCatalog.ParseError.self) {
            _ = try StreamCatalog.parse(metaJSON: Data("not json".utf8))
        }
        #expect(throws: StreamCatalog.ParseError.self) {
            _ = try StreamCatalog.parse(metaJSON: Data("[]".utf8))
        }
        // An array of objects with no usable Url is not a catalog either.
        #expect(throws: StreamCatalog.ParseError.self) {
            _ = try StreamCatalog.parse(metaJSON: Data(#"[{"Bandwidth":1}]"#.utf8))
        }
    }

    // MARK: - Single-track selection

    @Test("A single video track produces a filter that matches only it")
    func singleVideoIsExact() throws {
        let catalog = try Self.loadCatalog()
        // The two 640x360 tracks differ only by codec, so this exercises real
        // ambiguity rather than a trivially unique pick.
        let target = try #require(
            catalog.video.first { $0.resolution == "640x360" && $0.codecs == "avc1.64001e" }
        )

        let filter = catalog.filter(kind: .video, chosen: [target])
        guard case .exact(let flag, let value) = filter else {
            Issue.record("expected an exact filter, got \(filter)")
            return
        }
        #expect(flag == "-sv")
        #expect(value.contains("res=^640x360$"))
        #expect(value.contains(#"codecs=^avc1\.64001e$"#))
        #expect(value.contains("for=all"))
        // Values must not contain a colon: the engine truncates there.
        #expect(!value.dropFirst().contains(":") || !value.contains("://"))
    }

    @Test("The two same-resolution video tracks are told apart")
    func sameResolutionTracksAreDistinguished() throws {
        let catalog = try Self.loadCatalog()
        let pair = catalog.video.filter { $0.resolution == "640x360" }
        #expect(pair.count == 2, "fixture no longer has the ambiguous pair")

        for target in pair {
            let filter = catalog.filter(kind: .video, chosen: [target])
            #expect(
                filter != .inexpressible(kind: .video, wouldAlsoMatch: []),
                "\(target.codecs ?? "?") could not be expressed"
            )
            if case .inexpressible(_, let extra) = filter {
                Issue.record("filter for \(target.summary) also matches \(extra.map(\.summary))")
            }
        }
    }

    @Test("An audio track is distinguished from its Audio Descriptions twin")
    func audioDescriptionsAreNotConfused() throws {
        let catalog = try Self.loadCatalog()
        // "English Audio" is a prefix of "English Audio Descriptions", and the
        // engine matches with IsMatch (substring), so an unanchored name filter
        // would select both.
        let target = try #require(
            catalog.audio.first { $0.groupID == "2ch" && $0.name == "English Audio" }
        )

        let filter = catalog.filter(kind: .audio, chosen: [target])
        guard case .exact(_, let value) = filter else {
            Issue.record("expected an exact filter, got \(filter)")
            return
        }
        #expect(value.contains("name=^English Audio$"), "the name clause must be anchored")
    }

    @Test("Every single track in the catalog is individually expressible")
    func everyTrackIsExpressible() throws {
        // A blanket guarantee: whatever the user clicks, the filter is exact.
        let catalog = try Self.loadCatalog()
        for stream in catalog.streams {
            let filter = catalog.filter(kind: stream.kind, chosen: [stream])
            if case .inexpressible(_, let extra) = filter {
                Issue.record(
                    "\(stream.kind) \(stream.summary) is inexpressible; also matches \(extra.map(\.summary))"
                )
            }
        }
    }

    // MARK: - Multi-track selection

    @Test("Two audio tracks differing in one field are expressible together")
    func twoAudioTracksOneFieldApart() throws {
        let catalog = try Self.loadCatalog()
        // Both are 2ch English; only Name differs, so a single alternation suffices
        // and no cross product can arise.
        let chosen = catalog.audio.filter { $0.groupID == "2ch" }
        #expect(chosen.count == 2)

        let filter = catalog.filter(kind: .audio, chosen: chosen)
        guard case .exact(_, let value) = filter else {
            Issue.record("expected an exact filter, got \(filter)")
            return
        }
        #expect(value.contains("|"), "expected an alternation over Name")
        #expect(value.contains("for=all"))
    }

    @Test("A cross-product selection is reported instead of silently over-matching")
    func crossProductIsRejected() throws {
        let catalog = try Self.loadCatalog()
        // 16ch "English Audio" plus 2ch "English Audio Descriptions": two fields
        // differ, so alternating both also matches 16ch Descriptions and 2ch Audio
        // — tracks the user did not choose. The engine takes one filter per kind
        // with its fields ANDed, so this genuinely cannot be expressed.
        let a = try #require(
            catalog.audio.first { $0.groupID == "16ch" && $0.name == "English Audio" })
        let b = try #require(
            catalog.audio.first { $0.groupID == "2ch" && $0.name == "English Audio Descriptions" }
        )

        let filter = catalog.filter(kind: .audio, chosen: [a, b])
        guard case .inexpressible(let kind, let extra) = filter else {
            Issue.record("a cross-product selection was accepted as exact: \(filter)")
            return
        }
        #expect(kind == .audio)
        #expect(!extra.isEmpty, "should name the tracks that would also be matched")
    }

    @Test("Selecting every track of a kind is expressible")
    func selectingAllIsExpressible() throws {
        let catalog = try Self.loadCatalog()
        for kind in MediaStream.Kind.allCases {
            let all = catalog.streams.filter { $0.kind == kind }
            guard !all.isEmpty else { continue }
            let filter = catalog.filter(kind: kind, chosen: all)
            if case .inexpressible(_, let extra) = filter {
                Issue.record("selecting all \(kind) failed; extra: \(extra.count)")
            }
        }
    }

    @Test("filters(for:) covers each kind that has a selection")
    func filtersCoverSelectedKinds() throws {
        let catalog = try Self.loadCatalog()
        let video = try #require(catalog.video.first { $0.codecs == "avc1.64001e" })
        let audio = try #require(
            catalog.audio.first { $0.groupID == "2ch" && $0.name == "English Audio" })
        let subtitle = try #require(catalog.subtitles.first)

        let selection: Set<String> = [video.id, audio.id, subtitle.id]
        let filters = catalog.filters(for: selection)

        #expect(filters.count == 3)
        let flags = filters.compactMap { filter -> String? in
            if case .exact(let flag, _) = filter { return flag }
            return nil
        }
        #expect(Set(flags) == ["-sv", "-sa", "-ss"])
    }

    @Test("An empty selection produces no filters")
    func emptySelectionProducesNothing() throws {
        let catalog = try Self.loadCatalog()
        #expect(catalog.filters(for: []).isEmpty)
    }

    // MARK: - Regex escaping

    @Test("Regex metacharacters in field values are escaped")
    func metacharactersAreEscaped() {
        #expect(StreamCatalog.escapeForRegex("avc1.64001e") == #"avc1\.64001e"#)
        #expect(StreamCatalog.escapeForRegex("a+b") == #"a\+b"#)
        #expect(StreamCatalog.escapeForRegex("x(y)") == #"x\(y\)"#)
        #expect(StreamCatalog.escapeForRegex("a|b") == #"a\|b"#)
    }

    @Test("Colons are deliberately left unescaped")
    func colonsAreNotEscaped() {
        // The engine's parser truncates a value at an unescaped colon and strips
        // every accumulated backslash when it meets an escaped one, corrupting the
        // other escapes in the same pattern. Values containing a colon are dropped
        // from the filter earlier instead.
        #expect(StreamCatalog.escapeForRegex("a:b") == "a:b")
    }

    @Test("A colon in a field value does not end up in the filter")
    func colonBearingFieldIsSkipped() throws {
        // Synthetic, because the real capture has no such value. Two tracks whose
        // only distinguishing field contains a colon: the field must be skipped,
        // and because that makes them indistinguishable the result must be reported
        // as inexpressible rather than silently truncated.
        let json = """
            [
              {"Url":"https://a/1","MediaType":"AUDIO","GroupId":"g","Language":"en","Name":"Track: One","Channels":"2"},
              {"Url":"https://a/2","MediaType":"AUDIO","GroupId":"g","Language":"en","Name":"Track: Two","Channels":"2"}
            ]
            """
        let catalog = try StreamCatalog.parse(metaJSON: Data(json.utf8))
        let first = try #require(catalog.audio.first)

        let filter = catalog.filter(kind: .audio, chosen: [first])
        if case .exact(_, let value) = filter {
            #expect(
                !value.contains("Track"), "a colon-bearing value leaked into the filter: \(value)")
        }
        // With Name unusable the two tracks are identical, so this must be honest
        // about not being able to express the choice.
        if case .exact = filter {
            Issue.record("two indistinguishable tracks were reported as exactly selectable")
        }
    }

    // MARK: - Display

    @Test("Summaries are built for every kind without falling back to the URL")
    func summariesAreDescriptive() throws {
        let catalog = try Self.loadCatalog()
        for stream in catalog.streams {
            #expect(stream.summary != stream.url, "\(stream.kind) fell back to its URL")
            #expect(!stream.summary.isEmpty)
        }
    }
}
