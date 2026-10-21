import Foundation

/// Locates the external executables the app drives: the bundled N_m3u8DL-RE
/// download engine, and the system ffmpeg used for muxing.
///
/// ## Why explicit paths are probed instead of relying on `PATH`
///
/// A GUI app launched from Finder/Dock does **not** inherit the user's shell
/// `PATH`. It gets a minimal environment (roughly `/usr/bin:/bin:/usr/sbin:/sbin`),
/// which excludes both Homebrew prefixes. So a plain "look it up on PATH" search
/// finds Homebrew's ffmpeg when the app is run from a terminal and silently
/// fails to find it when the same app is double-clicked — the worst kind of bug,
/// because it looks like it works during development. Well-known locations are
/// therefore probed explicitly, and `PATH` is only a last resort.
nonisolated enum ToolLocator {

    // MARK: - Tools

    enum Tool {
        /// The download engine, produced by scripts/build-engine.sh and copied
        /// into the app bundle's Resources.
        case engine
        /// ffmpeg, deliberately NOT bundled: this project uses whatever the
        /// system provides.
        case ffmpeg

        var executableName: String {
            switch self {
            case .engine: return "N_m3u8DL-RE"
            case .ffmpeg: return "ffmpeg"
            }
        }

        /// `UserDefaults` key holding a user-chosen override path.
        var overrideDefaultsKey: String {
            switch self {
            case .engine: return "enginePathOverride"
            case .ffmpeg: return "ffmpegPathOverride"
            }
        }
    }

    // MARK: - Resolution

    /// How a tool was found, so the UI can explain itself to the user.
    enum Source: Equatable {
        /// An explicit path the user picked in Settings.
        case userOverride
        /// Shipped inside `MyApp.app/Contents/Resources`.
        case appBundle
        /// One of the well-known install locations (Homebrew, /usr/local, ...).
        case knownLocation
        /// Found by searching `PATH`.
        case searchPath
    }

    struct Resolved: Equatable {
        let url: URL
        let source: Source
    }

    enum LocateError: LocalizedError, Equatable {
        case notFound(Tool)
        case notExecutable(Tool, URL)

        var errorDescription: String? {
            switch self {
            case .notFound(let tool):
                switch tool {
                case .engine:
                    return "The N_m3u8DL-RE download engine was not found."
                case .ffmpeg:
                    return "ffmpeg was not found."
                }
            case .notExecutable(let tool, let url):
                return "\(tool.executableName) at \(url.path) is not executable."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .notFound(.engine):
                return """
                    Build it from the bundled submodule:
                        ./scripts/build-engine.sh
                    then rebuild the app, or set an explicit path in Settings.
                    """
            case .notFound(.ffmpeg):
                return """
                    Install it, for example:
                        brew install ffmpeg
                    or set an explicit path in Settings.
                    """
            case .notExecutable:
                return "Check the file's permissions, or pick a different path in Settings."
            }
        }
    }

    /// Well-known absolute locations, in priority order. Homebrew on Apple
    /// silicon uses /opt/homebrew; Intel Homebrew and manual installs use
    /// /usr/local.
    private static let knownDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",  // MacPorts
        "/usr/bin",
    ]

    /// Resolves `tool` to a runnable executable.
    ///
    /// - Parameter defaults: injected so this is testable without touching the
    ///   real user defaults.
    static func locate(
        _ tool: Tool,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Result<Resolved, LocateError> {
        // 1. An explicit user choice always wins, and never falls through to a
        //    different binary: silently substituting something else would hide
        //    a misconfigured path.
        if let override = defaults.string(forKey: tool.overrideDefaultsKey),
            !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            guard fileManager.isExecutableFile(atPath: url.path) else {
                return .failure(.notExecutable(tool, url))
            }
            return .success(Resolved(url: url, source: .userOverride))
        }

        // 2. Bundled copy (engine only; ffmpeg is intentionally not shipped).
        if tool == .engine,
            let bundled = Bundle.main.url(forResource: tool.executableName, withExtension: nil),
            fileManager.isExecutableFile(atPath: bundled.path)
        {
            return .success(Resolved(url: bundled, source: .appBundle))
        }

        // 3. Well-known locations, because PATH is unreliable under Finder launch.
        for directory in knownDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(tool.executableName)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return .success(Resolved(url: candidate, source: .knownLocation))
            }
        }

        // 4. Last resort: whatever PATH says, which is only populated when the
        //    app was started from a shell.
        if let fromPath = searchExecutablePath(for: tool.executableName, fileManager: fileManager) {
            return .success(Resolved(url: fromPath, source: .searchPath))
        }

        return .failure(.notFound(tool))
    }

    private static func searchExecutablePath(
        for name: String,
        fileManager: FileManager
    ) -> URL? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
