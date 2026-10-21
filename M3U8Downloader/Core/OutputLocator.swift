import Foundation

/// Where a job's output ends up, and which files in it belong to the job.
///
/// Used both to launch the engine (its working directory) and to reveal the result in
/// Finder afterwards. They are one function on purpose: if "where does this write" and
/// "where do we look for it" were computed separately, a change to one would make the
/// Show in Finder button quietly open the wrong folder.
nonisolated enum OutputLocator {

    /// The directory a download writes into: the chosen save directory, or Downloads.
    ///
    /// Falling back to the process's current directory would put files somewhere arbitrary
    /// for a Finder-launched app, so Downloads is used instead.
    static func directory(
        saveDirectory: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let saveDirectory, !saveDirectory.isEmpty {
            return URL(fileURLWithPath: saveDirectory)
        }
        return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// `~` and `~/…` to the home directory.
    ///
    /// For the arguments handed to the engine. `URL(fileURLWithPath:)` expands a leading `~`
    /// by itself (measured: `~/Movies` gives `/Users/…/Movies`), so `directory(saveDirectory:)`
    /// needs nothing, but the engine receives the raw string. That .NET does not expand it
    /// is the general behaviour of `Directory.CreateDirectory`, **not verified against this
    /// engine** — a local HTTP server could not be started in the sandbox to test it. The
    /// expansion is harmless if the engine already did it.
    static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return (path as NSString).expandingTildeInPath
    }

    /// Files in `directory` that belong to a download called `saveName`.
    ///
    /// Matched by name prefix and by modification time, **both**:
    ///
    /// - The prefix alone would select last week's download of the same title.
    /// - The time alone would select whatever else happens to be written to Downloads
    ///   while a long download runs — a browser's, for instance.
    ///
    /// A prefix rather than an exact name because one download can produce several files
    /// (`name.mp4`, `name.en.srt`), and every one of them is returned: Finder can highlight
    /// them all, which avoids guessing which is "the" output.
    ///
    /// `slack` absorbs the gap between the app recording a start time and the filesystem
    /// stamping the first write; coarse-grained timestamps can otherwise land just before it.
    static func files(
        in directory: URL,
        namedLike saveName: String,
        modifiedSince start: Date,
        slack: TimeInterval = 2,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard !saveName.isEmpty,
            let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        return
            contents
            .filter { $0.lastPathComponent.hasPrefix(saveName) }
            .filter { url in
                let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .isRegularFileKey,
                ])
                // Directories are skipped: the engine's temporary folder shares the save
                // name, and revealing it would point at scratch space.
                guard values?.isRegularFile == true,
                    let modified = values?.contentModificationDate
                else { return false }
                return modified >= start.addingTimeInterval(-slack)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
