import Foundation

/// Reassembles the engine's output from the arbitrary pieces the pipe delivers.
///
/// Feed it each drained piece; it returns the text that is safe to parse and keeps the
/// unfinished end back for the next piece. See `EngineOutputParser.splitUnfinishedTail` for what
/// "safe" means and why a split record would otherwise lose the engine's verdict.
///
/// Two ways the held-back tail still reaches the parser, so nothing is held forever:
///
/// - **An idle tick** (`feed(nil)`) releases it. The engine writes a record in one go, so
///   a record that has sat for a whole drain interval with nothing following is finished,
///   not split. Without this, the last line before a quiet phase such as merging would
///   not appear until the next one.
/// - **`finish`** releases it unconditionally when the process ends.
///
/// The cap is a guard rather than a measurement-backed limit: a tail is normally one
/// record or one progress token, a few hundred bytes (the multi-stream capture leaves 69).
/// It only matters if output arrives that never produces a boundary, where holding it would
/// grow without bound — and every drain tick re-scans the whole tail, so a large one is also
/// a slow one. It was 64 KB; the longest real tail is a .NET stack trace of a few KB.
///
/// 🔴 That is exactly what happened: a stream label longer than the progress pattern allowed
/// (see `EngineOutputParser.descriptionPattern`) left its text behind on every repaint, the
/// tail grew by ~350 bytes per tick, and the window froze when the scan time caught up.
nonisolated struct ChunkAssembler {

    private var carry = ""
    /// Size of the unfinished tail, for tests: it must stay small however long the run is.
    var carriedBytes: Int { carry.utf8.count }
    private let maximumCarryBytes: Int

    init(maximumCarryBytes: Int = 16 * 1024) {
        self.maximumCarryBytes = maximumCarryBytes
    }

    /// `piece == nil` means a drain tick that found nothing new.
    mutating func feed(_ piece: String?) -> String? {
        guard let piece else { return release() }

        let combined = carry + piece
        let (ready, tail) = EngineOutputParser.splitUnfinishedTail(of: combined)
        carry = tail

        if carry.utf8.count > maximumCarryBytes { return releaseAll(ready) }
        return ready.isEmpty ? nil : ready
    }

    /// The process ended: whatever is left is all there will ever be.
    mutating func finish(_ piece: String?) -> String? {
        let combined = carry + (piece ?? "")
        carry = ""
        return combined.isEmpty ? nil : combined
    }

    private mutating func release() -> String? {
        defer { carry = "" }
        return carry.isEmpty ? nil : carry
    }

    private mutating func releaseAll(_ ready: String) -> String? {
        let all = ready + carry
        carry = ""
        return all.isEmpty ? nil : all
    }
}
