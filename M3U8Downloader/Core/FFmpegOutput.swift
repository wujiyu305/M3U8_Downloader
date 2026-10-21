import Foundation

/// Reads ffmpeg's plain-text output, which has none of the engine's `LEVEL:` structure.
///
/// `DownloadCoordinator` used to record every ffmpeg line at `.info`, and the failure message
/// is built from the last `.error`/`.warn` record — so a failed metadata pass never had one
/// and the window said only "exited with code 1", with the actual reason (`No such file`,
/// `Invalid data found`, `already exists`) sitting unread in the collapsed log.
nonisolated enum FFmpegOutput {

    /// Phrases ffmpeg uses when something went wrong, lower-cased.
    ///
    /// Matched as substrings against lines that are not indented or banner text. A false
    /// positive only changes which line is quoted as the reason; a false negative loses the
    /// reason, which is the bug being fixed — so this errs towards matching.
    private static let errorPhrases = [
        "error", "invalid", "no such file", "not overwriting", "already exists",
        "could not", "unable to", "permission denied", "does not exist",
        "moov atom not found", "conversion failed", "not found", "failed",
    ]

    static func level(for line: String) -> EngineOutputParser.Level {
        // The version banner and its build configuration run to many indented lines of
        // `--enable-…` flags; none of it is about this run.
        if line.hasPrefix(" ") || line.hasPrefix("\t") { return .info }
        let lowered = line.lowercased()
        if lowered.hasPrefix("ffmpeg version") || lowered.contains("configuration:") {
            return .info
        }
        return errorPhrases.contains { lowered.contains($0) } ? .error : .info
    }

    /// ffmpeg's closing line on any failure. It says *that* the run failed, never why, so it
    /// is skipped when choosing the reason — the same treatment as the engine's own `Failed`.
    static func isGenericFailure(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines) == "Conversion failed!"
    }
}
