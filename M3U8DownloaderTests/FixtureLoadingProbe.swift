import Foundation
import Testing

@testable import M3U8Downloader

/// Proves the fixture-loading path actually works before any test relies on it.
///
/// This exists because `realCaptureLogRecords` passed while the fixture was
/// verifiably absent from the built `.xctest` bundle — a green test with missing
/// input is worse than no test, so the loader itself needs a probe that cannot
/// pass silently.
struct FixtureLoadingProbe {

    @Test("The fixture is reachable and its exact byte count matches the capture")
    func fixtureIsReachableWithExpectedSize() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-failed-download")

        // The capture on disk is 6080 bytes. Asserting the size (not merely
        // "non-empty") means a truncated or substituted file fails loudly.
        #expect(
            text.utf8.count == 6080,
            "fixture is \(text.utf8.count) bytes, expected 6080 — wrong or truncated file"
        )
    }

    @Test("The fixture contains the specific run-together record the parser must split")
    func fixtureContainsKnownContent() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-failed-download")

        // Byte-level facts from the capture. If the loader ever returns some other
        // file, these fail rather than quietly weakening the parser tests.
        #expect(text.contains("N_m3u8DL-RE (Beta version) 20260628"))
        #expect(
            text.contains("Content Matched: HTTP Live Streaming10:24:55.718"),
            "the missing-newline case is absent; the parser tests would prove nothing"
        )
        #expect(text.contains("0.00%"), "no progress token in the fixture")
        #expect(text.contains("tput:"), "no tput noise in the fixture")
    }

    @Test("Reports where the fixture was found, so the lookup path is not a mystery")
    func fixtureLocationIsKnown() throws {
        let found = Bundle.allBundles.compactMap {
            $0.url(forResource: "engine-stdout-failed-download", withExtension: "txt")
        }
        let viaFallback = Bundle.fixtureFallbackURL(name: "engine-stdout-failed-download")

        #expect(
            !found.isEmpty || viaFallback != nil,
            "fixture is not in any loaded bundle — tests depending on it are meaningless"
        )
    }

    @Test("A fixture that does not exist throws instead of yielding empty text")
    func missingFixtureThrows() {
        // Guards the failure mode directly: if the loader returned "" for a missing
        // file, every parser test would pass against empty input.
        #expect(throws: EngineOutputParserTests.FixtureError.self) {
            _ = try EngineOutputParserTests.loadFixture("definitely-not-a-real-fixture")
        }
    }

    // MARK: - The failed-verdict capture

    @Test("The failed-verdict capture is reachable and its exact byte count matches")
    func failedVerdictFixtureIsReachableWithExpectedSize() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-failed-verdict")

        #expect(
            text.utf8.count == 3107,
            "fixture is \(text.utf8.count) bytes, expected 3107 — wrong or truncated file"
        )
    }

    @Test("The failed-verdict capture contains the ERROR shapes the parser must accept")
    func failedVerdictFixtureContainsKnownContent() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-failed-verdict")

        // `ERROR:` with no space before the colon is the whole reason this file exists;
        // so is the tput noise glued onto the verdict with no newline between them.
        #expect(text.contains("ERROR: Segment count check not pass, total: 8, downloaded: 6."))
        #expect(
            text.contains("ERROR: Failedtput:"),
            "the verdict is not glued to the tput noise; the drop-the-record trap is untested"
        )
        #expect(text.contains("INFO : "), "the four-letter levels pad differently; both are needed")
    }

    // MARK: - The multi-stream capture

    @Test("The multi-stream capture is reachable and its exact byte count matches")
    func multiStreamFixtureIsReachableWithExpectedSize() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-multi-stream")

        #expect(
            text.utf8.count == 34286,
            "fixture is \(text.utf8.count) bytes, expected 34286 — wrong or truncated file"
        )
    }

    @Test("The multi-stream capture really contains three bars per repaint")
    func multiStreamFixtureContainsKnownContent() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-multi-stream")

        // The whole reason this file exists: three rows glued together with no newline,
        // the later ones still at Spectre's default 0/100.
        #expect(text.contains("Vid 640x360 | 800 Kbps"))
        #expect(text.contains("Aud English Audio | en"))
        #expect(text.contains("Sub en | English"))
        #expect(text.contains("0/100 0.00%"), "no unstarted task in the capture")
        #expect(
            text.contains("2/4 50.00% 768.00KB/3.00MB256.00KBps00:00:02"),
            "the video row's mid-download reading is missing"
        )
    }

    // MARK: - The progress capture

    @Test("The progress capture is reachable and its exact byte count matches")
    func progressFixtureIsReachableWithExpectedSize() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-progress")

        #expect(
            text.utf8.count == 10522,
            "fixture is \(text.utf8.count) bytes, expected 10522 — wrong or truncated file"
        )
    }

    @Test("The progress capture contains the shapes the parser is built around")
    func progressFixtureContainsKnownContent() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-progress")

        // These three are the measured token shapes. If the loader ever returns some
        // other file, this fails rather than quietly weakening the progress tests.
        #expect(
            text.contains("0/6 0.00% -0.00Bps --:--:--"),
            "the first repaint, where the size column is a dash, is missing"
        )
        #expect(
            text.contains("2/6 33.33% 608.00KB/3.56MB304.00KBps00:00:02"),
            "the mid-download shape with no separators is missing — the whole point"
        )
        #expect(
            text.contains("6/6 100.00%2.34MB - 00:00:00"),
            "the finished shape, where the speed column is a dash, is missing"
        )
    }
}
