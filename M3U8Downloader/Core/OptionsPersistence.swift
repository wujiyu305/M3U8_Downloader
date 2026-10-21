import Foundation

/// Persists the option panel's contents across launches.
///
/// ## Why this is not a preset system
///
/// The web generator stored *named* presets in Cloudflare KV behind an admin
/// password, because several people shared one deployment. A single-user Mac app
/// has no such problem, so there is no preset list, no naming and no sharing —
/// just one implicit "what you had last time".
///
/// ## Why the URL is deliberately not saved
///
/// A stream URL is single-use. Restoring it would put a stale link in front of the
/// user on every launch, and it is the one field they must consciously provide, so
/// pre-filling it invites downloading the wrong thing. Everything *around* it
/// (headers, save directory, thread count, mux settings) is what gets reused.
///
/// ## Why credentials are not saved
///
/// "Headers get reused" was too broad. A `Cookie` or `Authorization` header belongs to one
/// site, and restoring it sent it to whatever the next download's host was — a leak the user
/// could not see, from a plist that also held it in plain text. So headers that carry a
/// credential, decryption keys, a custom HLS key/IV and a proxy with a password are never
/// written, and anything already on disk is scrubbed on the next load. Harmless headers
/// (`Referer`, `User-Agent`, `Origin`) are still remembered; those are what a series needs.
nonisolated struct OptionsPersistence {

    /// Bumped when the stored shape changes incompatibly. A mismatch discards the
    /// old value rather than trying to migrate: losing remembered form fields is
    /// harmless, while a half-decoded options struct could silently produce wrong
    /// arguments.
    ///
    /// **2** renamed `metadata` to `metadataDefaults`. That rename happened to be
    /// safe on its own — the old key simply stopped decoding, which discarded the
    /// bad "metadata enabled with no paths" state that was disabling Add and
    /// Download. Relying on that was luck, not design: a future rename could leave
    /// a struct partly populated instead. Bump this whenever a stored field is
    /// renamed, removed or changes meaning.
    static let currentVersion = 2

    private enum Key {
        static let options = "lastDownloadOptions"
        static let metadata = "lastMetadataOptions"
        static let version = "lastOptionsVersion"
    }

    /// What actually gets written: the draft options with volatile fields cleared.
    struct Stored: Codable, Equatable {
        var options: DownloadOptions
        /// Reusable metadata fields (title, description, date) *without* the file
        /// paths. Never used to re-enable the pass — `ContentView` restores the
        /// pass as off and only uses this to pre-fill the fields once the user
        /// switches it back on.
        var metadataDefaults: MetadataOptions?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Saving

    func save(options: DownloadOptions, metadata: MetadataOptions?) {
        var sanitized = Self.sanitized(options)
        // Per-download values are cleared: restoring them would silently reuse
        // last time's target.
        sanitized.input = ""
        sanitized.basic.saveName = nil
        // Filled in automatically from ToolLocator on every run, so storing it
        // would pin a path that may have moved.
        sanitized.advanced.ffmpegBinaryPath = nil

        // The metadata pass is stored with its reusable fields but **switched off**.
        //
        // Keeping it enabled while clearing the per-download paths restored a state
        // that can never validate: "An input file is required." plus "An output file
        // is required." on every launch, which disabled both Add and Download with
        // no obvious cause — worse still if the Metadata section was collapsed, and
        // baffling next to a perfectly good URL. The paths refer to one finished
        // file, so they cannot be kept; the only coherent choice is to restore the
        // pass as off and let the user switch it on when they have a file.
        let sanitizedMetadata = metadata.map { current -> MetadataOptions in
            var copy = current
            copy.inputPath = ""
            copy.outputPath = ""
            copy.coverImagePath = nil
            return copy
        }

        let stored = Stored(options: sanitized, metadataDefaults: sanitizedMetadata)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Key.options)
        defaults.set(Self.currentVersion, forKey: Key.version)
    }

    // MARK: - Loading

    /// Returns the stored options, or `nil` on a first launch, a version mismatch,
    /// or unreadable data.
    ///
    /// A stored metadata pass is returned **disabled**: see `save` for why an
    /// enabled-but-pathless pass must never be restored.
    func load() -> Stored? {
        guard defaults.integer(forKey: Key.version) == Self.currentVersion,
            let data = defaults.data(forKey: Key.options),
            var stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }

        // Data written before credentials were excluded may hold some. Scrub it from what is
        // returned *and* from disk now: nothing re-saves at launch (the restored draft equals
        // what is stored), so without this the secret would sit in the plist until the user
        // happened to change a setting.
        let clean = Self.sanitized(stored.options)
        if clean != stored.options {
            stored.options = clean
            if let rewritten = try? JSONEncoder().encode(stored) {
                defaults.set(rewritten, forKey: Key.options)
            }
        }
        return stored
    }

    // MARK: - Credentials

    /// `options` with everything that must not be written to disk removed.
    static func sanitized(_ options: DownloadOptions) -> DownloadOptions {
        var options = options
        options.network.headers.removeAll { isCredentialHeader($0.name) }
        if let proxy = options.network.customProxy, proxyCarriesCredentials(proxy) {
            options.network.customProxy = nil
        }
        options.merge.keys = []
        options.merge.customHLSKey = nil
        options.merge.customHLSIV = nil
        return options
    }

    /// Names that identify a credential. Matched by substring, so `X-Auth-Token` and
    /// `X-Api-Key` are caught as well as the standard ones; it errs towards forgetting a
    /// harmless header over remembering a secret.
    static func isCredentialHeader(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["cookie", "auth", "token", "key", "secret", "session", "password", "credential"]
            .contains { lowered.contains($0) }
    }

    /// A proxy URL with a user name or password in it, e.g. `http://user:pass@host:8080`.
    static func proxyCarriesCredentials(_ proxy: String) -> Bool {
        guard let components = URLComponents(string: proxy) else {
            // Unparseable: judge by the one shape that matters, an `@` before the host.
            return proxy.contains("@")
        }
        return components.user != nil || components.password != nil
    }

    /// Forgets the stored options, for a "reset to defaults" action.
    func clear() {
        defaults.removeObject(forKey: Key.options)
        defaults.removeObject(forKey: Key.metadata)
        defaults.removeObject(forKey: Key.version)
    }
}
