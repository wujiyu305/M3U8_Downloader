import Foundation
import Testing

@testable import M3U8Downloader

/// Tests for remembering the option panel across launches.
///
/// Uses an isolated `UserDefaults` suite per test rather than `.standard`, so a
/// test run cannot read or overwrite the developer's own saved settings.
struct OptionsPersistenceTests {

    /// A throwaway suite, removed afterwards so nothing accumulates in the
    /// preferences store.
    private func withIsolatedDefaults(
        _ body: (OptionsPersistence, UserDefaults) throws -> Void
    ) throws {
        let suiteName = "OptionsPersistenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(OptionsPersistence(defaults: defaults), defaults)
    }

    // MARK: - Round trip

    @Test("Settings survive a save and load")
    func roundTrip() throws {
        try withIsolatedDefaults { persistence, _ in
            var options = DownloadOptions()
            options.network.threadCount = 12
            options.network.headers = [
                .init(name: "Referer", value: "https://example.com/"),
                .init(name: "User-Agent", value: "Mozilla/5.0"),
            ]
            options.basic.saveDirectory = "/Users/me/Movies"
            options.merge.muxAfterDone = MuxAfterDone(format: .mkv, keep: true)
            options.selection.autoSelect = true
            options.advanced.logLevel = .debug

            persistence.save(options: options, metadata: nil)
            let restored = try #require(persistence.load())

            #expect(restored.options.network.threadCount == 12)
            #expect(restored.options.network.headers.count == 2)
            #expect(restored.options.network.headers.first?.name == "Referer")
            #expect(restored.options.basic.saveDirectory == "/Users/me/Movies")
            #expect(restored.options.merge.muxAfterDone?.format == .mkv)
            #expect(restored.options.merge.muxAfterDone?.keep == true)
            #expect(restored.options.selection.autoSelect == true)
            #expect(restored.options.advanced.logLevel == .debug)
        }
    }

    @Test("A tri-state option that was never set stays unset after a round trip")
    func unsetOptionsStayUnset() throws {
        try withIsolatedDefaults { persistence, _ in
            // This is the property the whole option model rests on: nil means "do
            // not pass this argument". If persistence turned nil into false, every
            // engine default would silently be overridden on the next launch.
            persistence.save(options: DownloadOptions(), metadata: nil)
            let restored = try #require(persistence.load())

            #expect(restored.options.network.useSystemProxy == nil)
            #expect(restored.options.merge.deleteAfterDone == nil)
            #expect(restored.options.network.threadCount == nil)
            #expect(restored.options.advanced.writeMetaJSON == nil)
            #expect(restored.options.selection.subtitleFormat == nil)
        }
    }

    @Test("An explicit false is preserved and not confused with unset")
    func explicitFalseIsPreserved() throws {
        try withIsolatedDefaults { persistence, _ in
            var options = DownloadOptions()
            options.merge.deleteAfterDone = false
            options.network.useSystemProxy = false

            persistence.save(options: options, metadata: nil)
            let restored = try #require(persistence.load())

            #expect(restored.options.merge.deleteAfterDone == false)
            #expect(restored.options.network.useSystemProxy == false)
        }
    }

    // MARK: - What must NOT be restored

    @Test("The stream URL is not restored")
    func urlIsNotRestored() throws {
        try withIsolatedDefaults { persistence, _ in
            // A stream URL is single-use. Restoring it would present a stale link
            // as if it were the intended target, and this is the one field the user
            // must consciously supply.
            var options = DownloadOptions()
            options.input = "https://example.com/private-stream.m3u8"
            options.network.threadCount = 8

            persistence.save(options: options, metadata: nil)
            let restored = try #require(persistence.load())

            #expect(restored.options.input.isEmpty, "the URL came back: \(restored.options.input)")
            // The surrounding configuration must still be there.
            #expect(restored.options.network.threadCount == 8)
        }
    }

    @Test("The save name is not restored")
    func saveNameIsNotRestored() throws {
        try withIsolatedDefaults { persistence, _ in
            // Per-download like the URL: reusing it would overwrite or collide with
            // the previous download's output.
            var options = DownloadOptions()
            options.basic.saveName = "Episode 1"
            options.basic.saveDirectory = "/Users/me/Movies"

            persistence.save(options: options, metadata: nil)
            let restored = try #require(persistence.load())

            #expect(restored.options.basic.saveName == nil)
            // The directory is reusable and must survive.
            #expect(restored.options.basic.saveDirectory == "/Users/me/Movies")
        }
    }

    @Test("The ffmpeg path is not restored")
    func ffmpegPathIsNotRestored() throws {
        try withIsolatedDefaults { persistence, _ in
            // The coordinator fills this in from ToolLocator on every run. Storing
            // it would pin a path that may have moved after a Homebrew upgrade.
            var options = DownloadOptions()
            options.advanced.ffmpegBinaryPath = "/opt/homebrew/bin/ffmpeg"

            persistence.save(options: options, metadata: nil)
            let restored = try #require(persistence.load())

            #expect(restored.options.advanced.ffmpegBinaryPath == nil)
        }
    }

    @Test("Metadata keeps its reusable settings but drops the file paths")
    func metadataPathsAreNotRestored() throws {
        try withIsolatedDefaults { persistence, _ in
            var metadata = MetadataOptions()
            metadata.inputPath = "/Users/me/Movies/ep1.mp4"
            metadata.outputPath = "/Users/me/Movies/ep1_meta.mp4"
            metadata.coverImagePath = "/Users/me/cover.jpg"
            metadata.title = "My Show"

            persistence.save(options: DownloadOptions(), metadata: metadata)
            let restored = try #require(persistence.load())
            let defaults = try #require(restored.metadataDefaults)

            // Paths point at one finished file, so they are per-download.
            #expect(defaults.inputPath.isEmpty)
            #expect(defaults.outputPath.isEmpty)
            #expect(defaults.coverImagePath == nil)
            // The title is reusable across a series.
            #expect(defaults.title == "My Show")
        }
    }

    @Test("The stored metadata never validates as-is, so it must not re-enable the pass")
    func storedMetadataWouldNotValidate() throws {
        // This is the bug that disabled both Add and Download on every launch: the
        // pass was restored enabled while its paths had been cleared, so
        // MetadataCommandBuilder.validate always reported two problems and the
        // buttons stayed greyed out with no obvious cause.
        try withIsolatedDefaults { persistence, _ in
            var metadata = MetadataOptions()
            metadata.inputPath = "/Users/me/a.mp4"
            metadata.outputPath = "/Users/me/a_meta.mp4"
            persistence.save(options: DownloadOptions(), metadata: metadata)

            let stored = try #require(persistence.load().flatMap(\.metadataDefaults))
            #expect(
                !MetadataCommandBuilder.validate(stored).isEmpty,
                "if this ever validates, the reasoning below needs revisiting"
            )
            // Therefore `Stored` exposes it as `metadataDefaults` — pre-fill data —
            // and ContentView restores the pass itself as off.
        }
    }

    @Test("A run with the metadata pass off stores no metadata defaults")
    func metadataDisabledStoresNothing() throws {
        try withIsolatedDefaults { persistence, _ in
            persistence.save(options: DownloadOptions(), metadata: nil)
            let restored = try #require(persistence.load())
            #expect(restored.metadataDefaults == nil)
        }
    }

    // MARK: - First launch and bad data

    @Test("A first launch has nothing to restore")
    func firstLaunchLoadsNothing() throws {
        try withIsolatedDefaults { persistence, _ in
            #expect(persistence.load() == nil)
        }
    }

    @Test("A version mismatch discards the stored value instead of misreading it")
    func versionMismatchDiscards() throws {
        try withIsolatedDefaults { persistence, defaults in
            persistence.save(options: DownloadOptions(), metadata: nil)
            #expect(persistence.load() != nil)

            // Simulate data written by a future or older build.
            defaults.set(OptionsPersistence.currentVersion + 1, forKey: "lastOptionsVersion")
            #expect(
                persistence.load() == nil,
                "stale data was accepted; a partially-decoded options struct could produce wrong arguments"
            )
        }
    }

    @Test("Corrupt data is ignored rather than crashing")
    func corruptDataIsIgnored() throws {
        try withIsolatedDefaults { persistence, defaults in
            defaults.set(Data([0x00, 0x01, 0x02]), forKey: "lastDownloadOptions")
            defaults.set(OptionsPersistence.currentVersion, forKey: "lastOptionsVersion")

            #expect(persistence.load() == nil)
        }
    }

    @Test("Clearing forgets everything")
    func clearForgetsEverything() throws {
        try withIsolatedDefaults { persistence, _ in
            var options = DownloadOptions()
            options.network.threadCount = 16
            persistence.save(options: options, metadata: nil)
            #expect(persistence.load() != nil)

            persistence.clear()
            #expect(persistence.load() == nil)
        }
    }

    // MARK: - Interaction with argument building

    @Test("Restored settings produce the same arguments as before saving")
    func restoredOptionsBuildIdenticalArguments() throws {
        try withIsolatedDefaults { persistence, _ in
            // The point of persistence is that the next run behaves the same. Assert
            // on the argv, which is what actually reaches the engine, rather than
            // just field equality.
            var options = DownloadOptions()
            options.network.threadCount = 12
            options.network.headers = [.init(name: "Referer", value: "https://example.com/")]
            options.merge.muxAfterDone = MuxAfterDone(format: .mkv)
            options.merge.deleteAfterDone = false
            options.advanced.logLevel = .debug

            persistence.save(options: options, metadata: nil)
            var restored = try #require(persistence.load()).options

            // Re-supply the two per-download fields the user would provide again.
            let url = "https://example.com/a.m3u8"
            options.input = url
            restored.input = url

            #expect(
                CommandBuilder.arguments(for: restored) == CommandBuilder.arguments(for: options)
            )
        }
    }
}

// MARK: - Credentials

struct OptionsCredentialTests {

    private func withIsolatedDefaults(
        _ body: (OptionsPersistence, UserDefaults) throws -> Void
    ) throws {
        let suiteName = "OptionsCredentialTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(OptionsPersistence(defaults: defaults), defaults)
    }

    private func secretOptions() -> DownloadOptions {
        var options = DownloadOptions()
        options.network.headers = [
            .init(name: "Cookie", value: "session=SECRET-COOKIE"),
            .init(name: "Authorization", value: "Bearer SECRET-BEARER"),
            .init(name: "X-Api-Key", value: "SECRET-APIKEY"),
            .init(name: "Referer", value: "https://example.com/"),
            .init(name: "User-Agent", value: "Mozilla/5.0"),
        ]
        options.network.customProxy = "http://user:SECRET-PROXY@127.0.0.1:8080"
        options.merge.keys = ["SECRET-KEY:00112233"]
        options.merge.customHLSKey = "SECRET-HLSKEY"
        options.merge.customHLSIV = "SECRET-HLSIV"
        return options
    }

    @Test("Credentials never reach the stored bytes")
    func secretsAreNotWritten() throws {
        try withIsolatedDefaults { persistence, defaults in
            persistence.save(options: secretOptions(), metadata: nil)

            let data = try #require(defaults.data(forKey: "lastDownloadOptions"))
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("SECRET"), "a credential was written to disk")
        }
    }

    @Test("Harmless headers are still remembered, in order")
    func harmlessHeadersSurvive() throws {
        try withIsolatedDefaults { persistence, _ in
            persistence.save(options: secretOptions(), metadata: nil)
            let restored = try #require(persistence.load()).options

            #expect(restored.network.headers.map(\.name) == ["Referer", "User-Agent"])
        }
    }

    @Test("Keys and a custom HLS key are not restored")
    func keysAreNotRestored() throws {
        try withIsolatedDefaults { persistence, _ in
            persistence.save(options: secretOptions(), metadata: nil)
            let restored = try #require(persistence.load()).options

            #expect(restored.merge.keys.isEmpty)
            #expect(restored.merge.customHLSKey == nil)
            #expect(restored.merge.customHLSIV == nil)
        }
    }

    @Test("A proxy with a password is dropped, a plain one is kept")
    func proxyCredentials() throws {
        try withIsolatedDefaults { persistence, _ in
            persistence.save(options: secretOptions(), metadata: nil)
            let withPassword = try #require(persistence.load())
            #expect(withPassword.options.network.customProxy == nil)

            var plain = DownloadOptions()
            plain.network.customProxy = "http://127.0.0.1:8080"
            persistence.save(options: plain, metadata: nil)
            let withoutPassword = try #require(persistence.load())
            #expect(withoutPassword.options.network.customProxy == "http://127.0.0.1:8080")
        }
    }

    @Test("Credential-bearing header names are recognised, others are not")
    func headerClassification() {
        for name in [
            "Cookie", "cookie", "Authorization", "Proxy-Authorization", "X-Auth-Token",
            "X-Api-Key", "X-Session-Id", "Set-Cookie",
        ] {
            #expect(OptionsPersistence.isCredentialHeader(name), "\(name)")
        }
        for name in ["Referer", "User-Agent", "Origin", "Accept-Language", "Range"] {
            #expect(!OptionsPersistence.isCredentialHeader(name), "\(name)")
        }
    }

    @Test("Proxy credentials are detected by shape")
    func proxyShapes() {
        #expect(OptionsPersistence.proxyCarriesCredentials("http://u:p@host:8080"))
        #expect(OptionsPersistence.proxyCarriesCredentials("http://u@host"))
        #expect(!OptionsPersistence.proxyCarriesCredentials("http://host:8080"))
        #expect(!OptionsPersistence.proxyCarriesCredentials("socks5://127.0.0.1:1080"))
    }

    @Test("Secrets already on disk from an older version are scrubbed on load")
    func legacyDataIsScrubbed() throws {
        try withIsolatedDefaults { persistence, defaults in
            // Written the way the old code did: no sanitising.
            let legacy = OptionsPersistence.Stored(
                options: secretOptions(), metadataDefaults: nil)
            defaults.set(try JSONEncoder().encode(legacy), forKey: "lastDownloadOptions")
            defaults.set(OptionsPersistence.currentVersion, forKey: "lastOptionsVersion")

            let restored = try #require(persistence.load()).options
            #expect(restored.network.headers.map(\.name) == ["Referer", "User-Agent"])
            #expect(restored.merge.keys.isEmpty)

            // And the plist itself no longer holds them — nothing else would rewrite it.
            let data = try #require(defaults.data(forKey: "lastDownloadOptions"))
            #expect(!String(decoding: data, as: UTF8.self).contains("SECRET"))
        }
    }
}
