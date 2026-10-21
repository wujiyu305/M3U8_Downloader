import Darwin
import Foundation

/// A process and everything it started, so stopping a download reaches all of it.
///
/// The engine spawns children of its own — ffmpeg to merge, mp4decrypt to decrypt, `tput`
/// on exit. Measured here: `Process` makes its child a process-group leader and
/// `Process.terminate()` already takes down grandchildren in that group, so a plain stop
/// works for the ordinary case. What it does not cover, and this does:
///
/// - **a grandchild that left the group** (its own `setsid`/`setpgid`), which terminate()
///   never reaches and which keeps our pipes open;
/// - **SIGKILL**, which terminate() never sends. The runner escalates to it after a grace
///   period, and needs the full list of who to kill.
///
/// Foundation offers no handle on the group, so the tree is walked with `libproc`.
/// Members carry their start time: by the time a delayed SIGKILL is sent the pid may have
/// been reused, and a bare pid would then kill an unrelated process.
nonisolated enum ProcessTree {

    struct Member: Equatable, Sendable {
        let pid: pid_t
        /// Start time, which together with the pid identifies one process for good.
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    /// `root` and all its descendants, root first. Empty if `root` is gone.
    static func members(rootedAt root: pid_t) -> [Member] {
        guard let rootMember = member(for: root) else { return [] }
        var result = [rootMember]
        var queue = [root]
        var seen: Set<pid_t> = [root]
        while let next = queue.popLast() {
            for child in children(of: next) where seen.insert(child).inserted {
                if let member = member(for: child) { result.append(member) }
                queue.append(child)
            }
        }
        return result
    }

    /// Whether this exact process (not merely this pid) still exists.
    static func isAlive(_ member: Member) -> Bool {
        Self.member(for: member.pid) == member
    }

    /// Signals the members that are still the processes they were when recorded.
    static func send(_ signal: Int32, to members: [Member]) {
        for member in members where isAlive(member) {
            kill(member.pid, signal)
        }
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        // Sized generously and retried once larger, because the call silently truncates.
        var capacity = 64
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = Int(
                proc_listchildpids(
                    pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
            guard count > 0 else { return [] }
            if count < capacity { return Array(buffer.prefix(count)).filter { $0 > 0 } }
            capacity *= 4
            if capacity > 65_536 { return Array(buffer.prefix(count)).filter { $0 > 0 } }
        }
    }

    private static func member(for pid: pid_t) -> Member? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // Returns the bytes written, or 0 if the process does not exist.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // A zombie has exited and only awaits being reaped; it cannot be signalled to
        // any effect and must not count as alive.
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        return Member(
            pid: pid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec)
    }
}
