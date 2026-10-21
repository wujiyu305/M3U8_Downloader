import Foundation

/// Runs an external tool and streams its output as it arrives.
///
/// ## Why `Process` is driven manually rather than via a convenience wrapper
///
/// The engine needs three things that simple "run and collect output" helpers do
/// not provide:
///
/// - **Streaming.** A download runs for minutes; output must reach the UI as it
///   is produced, not at exit.
/// - **Interleaved, unterminated writes.** The engine repaints a progress bar
///   into the same stream as its log records without newlines, so reads happen on
///   arbitrary byte boundaries. Nothing here may assume a chunk ends at a line or
///   even at a UTF-8 character boundary.
/// - **Reliable cancellation.** Stopping a download must terminate the child, not
///   just abandon the read.
///
/// ## Deadlock avoidance
///
/// stdout and stderr are drained concurrently. Reading one to completion before
/// the other deadlocks as soon as the child fills the unread pipe's buffer (64 KB
/// by default) — a bug that only appears on long or verbose runs, which is exactly
/// when it hurts most.
nonisolated struct ProcessRunner {

    // MARK: - Output

    enum Stream: Sendable {
        case standardOutput
        case standardError
    }

    /// A chunk of text as it arrived. Never assume it is a whole line.
    struct Chunk: Sendable {
        let stream: Stream
        let text: String
    }

    struct Result: Sendable {
        let exitCode: Int32
        /// True when the process was ended by a signal, e.g. after cancellation.
        let wasTerminatedBySignal: Bool

        /// The engine exits 0 on success and 1 on any failure, so the exit code —
        /// not log scraping — decides the outcome.
        var isSuccess: Bool { exitCode == 0 && !wasTerminatedBySignal }
    }

    enum RunError: LocalizedError {
        case launchFailed(executable: URL, underlying: any Error)
        case notExecutable(URL)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let executable, let underlying):
                return "Could not start \(executable.lastPathComponent): "
                    + underlying.localizedDescription
            case .notExecutable(let url):
                return "\(url.path) is not an executable file."
            }
        }
    }

    // MARK: - Configuration

    let executable: URL
    let arguments: [String]
    /// Working directory for the child. The engine writes its output tree relative
    /// to this unless `--save-dir` says otherwise.
    let workingDirectory: URL?
    /// Extra environment entries merged over the parent's environment.
    let environment: [String: String]
    /// How long a cancelled process gets to exit after SIGTERM before it is killed.
    ///
    /// Long enough for the engine's exit handler to restore the terminal and flush its log;
    /// short enough that Stop and Quit do not feel stuck. A judgement call, not measured.
    let terminationGrace: TimeInterval

    init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        terminationGrace: TimeInterval = 5
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.terminationGrace = terminationGrace
    }

    // MARK: - Running

    /// Runs the tool, delivering output chunks to `onOutput` as they arrive.
    ///
    /// Cancelling the enclosing task terminates the child process. `onOutput` may
    /// be called from a background thread and is invoked with partial text.
    func run(
        onOutput: @escaping @Sendable (Chunk) -> Void
    ) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RunError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = childEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Give the child an explicit empty stdin. Without this it inherits ours,
        // and a child that reads stdin would block forever inside a GUI app.
        process.standardInput = FileHandle.nullDevice

        let decoder = StreamDecoder()

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(executable: executable, underlying: error)
        }

        // Terminate the child if the surrounding task is cancelled. Both pipes are
        // drained concurrently inside the group (see the deadlock note above);
        // `waitUntilExit` is blocking, so it runs off the cooperative pool.
        let result: Result = await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.drain(
                        outPipe.fileHandleForReading,
                        stream: .standardOutput,
                        decoder: decoder,
                        onOutput: onOutput
                    )
                }
                group.addTask {
                    await Self.drain(
                        errPipe.fileHandleForReading,
                        stream: .standardError,
                        decoder: decoder,
                        onOutput: onOutput
                    )
                }
                await group.waitForAll()
            }

            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    continuation.resume(
                        returning: Result(
                            exitCode: process.terminationStatus,
                            wasTerminatedBySignal: process.terminationReason == .uncaughtSignal
                        )
                    )
                }
            }
        } onCancel: {
            Self.stop(process, grace: terminationGrace)
        }

        // Flush anything the decoder was holding back mid-character.
        if let tail = decoder.flush(), !tail.isEmpty {
            onOutput(Chunk(stream: .standardOutput, text: tail))
        }
        return result
    }

    /// Asks the process and everything it started to exit, then makes sure they do.
    ///
    /// SIGTERM first, so the engine can run its exit handler (restore the terminal, flush
    /// its log) instead of leaving partial files with no record of why. Whatever is still
    /// alive after `grace` is killed outright: without that, a child that ignores SIGTERM,
    /// or a grandchild still holding our pipes, made Stop and Quit wait indefinitely.
    ///
    /// The tree is recorded **before** signalling. Once the root exits, its children are
    /// re-parented to launchd and can no longer be found from it.
    private static func stop(_ process: Process, grace: TimeInterval) {
        let root = process.processIdentifier
        guard process.isRunning, root > 0 else { return }

        let members = ProcessTree.members(rootedAt: root)
        ProcessTree.send(SIGTERM, to: members)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            // Anything started in the meantime is still under a living root — but only
            // if that root is still *our* process: a reused pid must not have its own
            // children killed.
            var late: [ProcessTree.Member] = []
            if let original = members.first, ProcessTree.isAlive(original) {
                late = ProcessTree.members(rootedAt: root)
            }
            ProcessTree.send(SIGKILL, to: members + late)
        }
    }

    /// The environment handed to the child.
    ///
    /// Inherits the parent's, applies the caller's overrides, then **removes
    /// variables a host injects that would break an unrelated child**. Both
    /// removals below fix measured failures, not hypothetical ones.
    ///
    /// ## Dynamic linker injection
    ///
    /// A host that sets `DYLD_INSERT_LIBRARIES` (Xcode Previews injects
    /// `__preview.dylib`; profiling and instrumentation tools do the same) passes it
    /// to every child. The engine is a separate executable, so dyld cannot load that
    /// library into it and kills the process before `main`:
    ///
    ///     dyld[…]: terminating because inserted dylib
    ///     '@executable_path/__preview.dylib' could not be loaded
    ///
    /// Measured: exit code **6** with only that dyld message, while the identical
    /// argv from a shell exited 0.
    ///
    /// ## `TERM`
    ///
    /// Xcode sets `TERM=dumb` for a debugged app. The engine's Spectre.Console
    /// progress bar reads `TERM` to size itself and, told the terminal has no
    /// capabilities, computes a width that makes its own renderer throw:
    ///
    ///     System.ArgumentException: Offset and length were out of bounds for the array…
    ///        at Spectre.Console.LiveRenderable.<Render>d__25.MoveNext()
    ///
    /// Measured on a real download, same argv each time: `TERM=dumb` → exit **134**,
    /// 0 bytes written; `TERM=xterm-256color` → exit 0, 17 MB; **`TERM` unset** →
    /// exit 0, 17 MB. Unset is therefore the safe choice — the child has no terminal
    /// either way, and Spectre handles an absent `TERM` correctly while explicitly
    /// being told "dumb" sends it down the broken path.
    private func childEnvironment() -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { _, new in new }
        for key in Self.hostInjectedKeysToStrip {
            merged.removeValue(forKey: key)
        }
        return merged
    }

    /// Variables a debugging or instrumenting host sets which must not reach an
    /// unrelated child executable.
    private static let hostInjectedKeysToStrip = [
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_ROOT_PATH",
        // See the `TERM` note above: Xcode's `TERM=dumb` crashes the engine's
        // progress renderer, whereas an absent TERM works.
        "TERM",
    ]

    /// Reads one pipe to EOF, forwarding decoded text.
    ///
    /// `static` so the task group does not have to capture `self`.
    private static func drain(
        _ handle: FileHandle,
        stream: Stream,
        decoder: StreamDecoder,
        onOutput: @escaping @Sendable (Chunk) -> Void
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                while true {
                    // availableData blocks until data arrives or the pipe closes,
                    // which is what makes this streaming rather than polling.
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if let text = decoder.decode(data, stream: stream), !text.isEmpty {
                        onOutput(Chunk(stream: stream, text: text))
                    }
                }
                continuation.resume()
            }
        }
    }
}

// MARK: - Incremental UTF-8 decoding

/// Decodes bytes to text across chunk boundaries.
///
/// Pipe reads split wherever the buffer happens to fill, which can be **inside** a
/// multi-byte character. The engine's progress bar is drawn with `━` (U+2501,
/// three bytes), so this is not hypothetical: a naive
/// `String(data:encoding:.utf8)` per chunk returns nil or a replacement character
/// exactly when a bar is being repainted, silently corrupting the text the parser
/// then sees.
///
/// Incomplete trailing bytes are held back and prepended to the next chunk. Each
/// stream is buffered separately so stdout and stderr cannot interleave into one
/// broken character.
///
/// `nonisolated` is required: this file's target defaults to MainActor isolation,
/// and this type is used from the background queues that drain the pipes.
private nonisolated final class StreamDecoder: @unchecked Sendable {
    private var pending: [ProcessRunner.Stream: Data] = [:]
    private let lock = NSLock()

    func decode(_ data: Data, stream: ProcessRunner.Stream) -> String? {
        lock.lock()
        defer { lock.unlock() }

        var buffer = pending[stream] ?? Data()
        buffer.append(data)

        // Find the longest prefix that is valid UTF-8 by trimming at most three
        // trailing bytes — the maximum length of an incomplete UTF-8 sequence.
        var cut = buffer.count
        var decoded: String?
        for candidate in stride(from: buffer.count, through: max(0, buffer.count - 3), by: -1) {
            if let text = String(data: buffer.prefix(candidate), encoding: .utf8) {
                decoded = text
                cut = candidate
                break
            }
        }

        guard let decoded else {
            // Nothing decodable yet; keep buffering. Guard against unbounded growth
            // from genuinely invalid bytes rather than a split character.
            if buffer.count > 4096 {
                pending[stream] = Data()
                return String(decoding: buffer, as: UTF8.self)
            }
            pending[stream] = buffer
            return nil
        }

        pending[stream] = buffer.suffix(from: buffer.startIndex + cut)
        return decoded
    }

    /// Returns any undecodable remainder at EOF, so trailing bytes are surfaced
    /// rather than silently dropped.
    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let leftovers = pending.values.filter { !$0.isEmpty }
        pending.removeAll()
        guard !leftovers.isEmpty else { return nil }
        return leftovers.map { String(decoding: $0, as: UTF8.self) }.joined()
    }
}
