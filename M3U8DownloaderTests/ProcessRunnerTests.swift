import Foundation
import Testing

@testable import M3U8Downloader

/// Tests for spawning tools and streaming their output.
///
/// These run **real** processes (`/bin/sh`, `/bin/cat`) rather than a mock. The
/// behaviours worth testing here — pipe buffering, cancellation, split multi-byte
/// characters — are properties of the OS, and a mock would assert only that the
/// mock behaves as written.
struct ProcessRunnerTests {

    // MARK: - Helpers

    /// Collects every chunk, since `onOutput` is called from background threads.
    private final class Collector: @unchecked Sendable {
        private var chunks: [ProcessRunner.Chunk] = []
        private let lock = NSLock()

        func append(_ chunk: ProcessRunner.Chunk) {
            lock.lock()
            chunks.append(chunk)
            lock.unlock()
        }

        var all: [ProcessRunner.Chunk] {
            lock.lock()
            defer { lock.unlock() }
            return chunks
        }

        func text(from stream: ProcessRunner.Stream? = nil) -> String {
            all.filter { stream == nil || $0.stream == stream }
                .map(\.text)
                .joined()
        }
    }

    private static func shell(_ script: String) -> ProcessRunner {
        ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]
        )
    }

    // MARK: - Basic execution

    @Test("stdout is captured")
    func capturesStandardOutput() async throws {
        let collector = Collector()
        let result = try await Self.shell("printf 'hello'").run { collector.append($0) }

        #expect(result.isSuccess)
        #expect(result.exitCode == 0)
        #expect(collector.text() == "hello")
    }

    @Test("stdout and stderr are captured separately")
    func separatesStreams() async throws {
        let collector = Collector()
        _ = try await Self.shell("printf 'out'; printf 'err' >&2").run {
            collector.append($0)
        }

        #expect(collector.text(from: .standardOutput) == "out")
        #expect(collector.text(from: .standardError) == "err")
    }

    @Test("A non-zero exit is reported rather than thrown")
    func reportsFailureExitCode() async throws {
        let result = try await Self.shell("exit 3").run { _ in }

        // The engine signals failure with exit 1, so a non-zero exit is a normal
        // outcome to report, not an error to throw.
        #expect(!result.isSuccess)
        #expect(result.exitCode == 3)
        #expect(!result.wasTerminatedBySignal)
    }

    @Test("Arguments are passed without shell interpretation")
    func argumentsAreNotShellInterpreted() async throws {
        let collector = Collector()
        // If this went through a shell, the subshell would execute and the output
        // would be a UID instead of the literal text.
        _ = try await ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["$(id -u)"]
        ).run { collector.append($0) }

        #expect(collector.text().trimmingCharacters(in: .whitespacesAndNewlines) == "$(id -u)")
    }

    // MARK: - Launch failures

    @Test("A missing executable throws before any process is spawned")
    func missingExecutableThrows() async {
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/nonexistent/tool"),
            arguments: []
        )
        await #expect(throws: ProcessRunner.RunError.self) {
            _ = try await runner.run { _ in }
        }
    }

    @Test("A path that exists but is not executable throws")
    func nonExecutableFileThrows() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-executable-\(UUID().uuidString).txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let runner = ProcessRunner(executable: file, arguments: [])
        await #expect(throws: ProcessRunner.RunError.self) {
            _ = try await runner.run { _ in }
        }
    }

    // MARK: - Streaming

    @Test("Output arrives while the process is still running")
    func outputIsStreamed() async throws {
        let collector = Collector()
        // Two writes separated in time: if output were only collected at exit, the
        // first chunk could not be observed before the process ended.
        _ = try await Self.shell("printf 'first'; sleep 0.4; printf 'second'").run {
            collector.append($0)
        }

        // Both parts must be present, and they should have arrived as separate
        // chunks given the delay between the writes.
        #expect(collector.text() == "firstsecond")
        #expect(collector.all.count >= 2, "output looks batched, not streamed")
    }

    @Test("A large volume of output does not deadlock")
    func largeOutputDoesNotDeadlock() async throws {
        let collector = Collector()
        // Well past the 64 KB pipe buffer, and on both streams at once: draining
        // one pipe to completion before the other would hang here.
        let result = try await Self.shell(
            """
            for i in $(seq 1 3000); do
                printf 'stdout line %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' "$i"
                printf 'stderr line %s bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\\n' "$i" >&2
            done
            """
        ).run { collector.append($0) }

        #expect(result.isSuccess)
        #expect(collector.text(from: .standardOutput).contains("stdout line 3000"))
        #expect(collector.text(from: .standardError).contains("stderr line 3000"))
    }

    // MARK: - Multi-byte characters split across reads

    @Test("A multi-byte character split across chunk boundaries is not corrupted")
    func splitMultibyteCharacterSurvives() async throws {
        // U+2501 (━, three bytes) is what the engine draws its progress bar with.
        //
        // The write pattern matters more than the character count. Many small
        // writes (`printf` in a loop) never split a character, because each write
        // lands in the pipe atomically — measured: 28114 reads, 0 splits, so a
        // test built that way passes even with a naive per-chunk decoder and
        // proves nothing. One large write does split: measured 19 reads with 18
        // cut mid-character, and naive decoding recovered only 1696 of 100000
        // characters. So the data is staged in a file and `cat` in one go.
        let count = 100_000
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bars-\(UUID().uuidString).txt")
        try String(repeating: "━", count: count).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let collector = Collector()
        let result = try await ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [file.path]
        ).run { collector.append($0) }

        #expect(result.isSuccess)
        let text = collector.text()
        #expect(
            text.count == count,
            "expected \(count) bar characters, got \(text.count) — decoder dropped split characters"
        )
        #expect(!text.contains("\u{FFFD}"), "replacement character found: text was corrupted")
        #expect(text == String(repeating: "━", count: count))
    }

    @Test("Mixed multi-byte text round-trips exactly across split reads")
    func mixedUnicodeRoundTrips() async throws {
        // CJK, the progress-bar character and an emoji outside the BMP, so the
        // stream carries both 3-byte and 4-byte sequences.
        //
        // The unit's byte length must NOT divide the pipe's read size, or the
        // splits never land mid-character. An earlier version used "下载中━🎬",
        // which is exactly 16 bytes; reads come back in 16384-byte chunks
        // (1024 x 16), so every boundary fell neatly between units and the test
        // passed even against a naive per-chunk decoder. Adding one ASCII byte
        // makes the unit 17 bytes, which is coprime with 16384.
        let unit = "下载中━🎬:"
        #expect(
            16384 % unit.utf8.count != 0,
            "unit is \(unit.utf8.count) bytes, which divides the read size — splits would never occur"
        )

        let repeats = 20_000
        let expected = String(repeating: unit, count: repeats)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("unicode-\(UUID().uuidString).txt")
        try expected.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let collector = Collector()
        _ = try await ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [file.path]
        ).run { collector.append($0) }

        let text = collector.text()
        // Derive the expectation from the string itself rather than a hand-counted
        // constant: an earlier version hardcoded 4 Characters per unit when it is
        // actually 5, and failed spuriously.
        #expect(text.count == unit.count * repeats)
        #expect(text == expected)
        #expect(!text.contains("\u{FFFD}"))
    }

    // MARK: - Cancellation

    @Test("Cancelling the task terminates the child process")
    func cancellationTerminatesChild() async throws {
        let collector = Collector()
        let started = Date()

        let task = Task {
            try await Self.shell("printf 'up'; sleep 30").run { collector.append($0) }
        }

        // Wait until the child has actually produced output, so cancellation lands
        // on a running process rather than racing the launch.
        while collector.text().isEmpty, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!collector.text().isEmpty, "child never started")

        task.cancel()
        let result = try await task.value
        let elapsed = Date().timeIntervalSince(started)

        // The 30-second sleep must not have run to completion.
        #expect(elapsed < 10, "cancellation did not stop the child (took \(elapsed)s)")
        #expect(!result.isSuccess, "a terminated process must not report success")
    }

    // MARK: - Environment and working directory

    @Test("Extra environment entries reach the child, merged over the parent's")
    func environmentIsMerged() async throws {
        let collector = Collector()
        _ = try await ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$M3U8_TEST_VAR\""],
            environment: ["M3U8_TEST_VAR": "injected"]
        ).run { collector.append($0) }

        #expect(collector.text() == "injected")
    }

    @Test("The parent environment is preserved when adding entries")
    func parentEnvironmentSurvives() async throws {
        let collector = Collector()
        _ = try await ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$HOME\""],
            environment: ["M3U8_TEST_VAR": "x"]
        ).run { collector.append($0) }

        #expect(!collector.text().isEmpty, "HOME went missing: parent env was replaced")
    }

    @Test("The working directory is honoured")
    func workingDirectoryIsUsed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-wd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let collector = Collector()
        _ = try await ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "pwd"],
            workingDirectory: directory
        ).run { collector.append($0) }

        // Compare resolved paths: /var is a symlink to /private/var on macOS, so
        // the raw strings differ even when the directory is correct.
        let reported = URL(
            fileURLWithPath: collector.text().trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(reported.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath())
    }

    // MARK: - stdin

    @Test("The child gets an empty stdin instead of inheriting ours")
    func stdinIsNullDevice() async throws {
        let collector = Collector()
        // A child that reads stdin must see EOF immediately. If it inherited the
        // parent's stdin inside a GUI app, this would block forever.
        let result = try await Self.shell("cat; printf 'done'").run { collector.append($0) }

        #expect(result.isSuccess)
        #expect(collector.text() == "done")
    }

    // MARK: - Dynamic linker injection

    /// Compiles a tiny probe that reports the `DYLD_INSERT_LIBRARIES` it received.
    ///
    /// A compiled binary in a temp directory is required, and `/bin/sh` cannot be
    /// used: SIP-protected system binaries have `DYLD_*` stripped by dyld itself
    /// before the process starts, so a shell-based probe reports an empty value
    /// whether or not `ProcessRunner` strips anything. Measured — with the
    /// stripping removed, a `/bin/sh` probe still printed `[]` and the test passed,
    /// proving nothing. Worse, a shell *forwards* the already-stripped environment,
    /// so even `sh -c '/path/to/unprotected'` hides the difference.
    private static func makeEnvironmentProbe() throws -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dyld-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("probe.c")
        try """
        #include <stdio.h>
        #include <stdlib.h>
        int main(void) {
            const char *v = getenv("DYLD_INSERT_LIBRARIES");
            printf("[%s]", v ? v : "");
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        let binary = directory.appendingPathComponent("probe")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["clang", "-o", binary.path, source.path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()

        guard compile.terminationStatus == 0,
            FileManager.default.isExecutableFile(atPath: binary.path)
        else { return nil }
        return binary
    }

    @Test("Dynamic linker injection is not passed to the child")
    func dyldInjectionIsStripped() async throws {
        // Not hypothetical: running the engine from a host that injects a dylib
        // (Xcode Previews inserts __preview.dylib) killed it before main with
        //   dyld[…]: terminating because inserted dylib '…' could not be loaded
        // and an exit code of 6, while the same argv from a shell exited 0. The
        // child is an unrelated executable, so it can never load the host's library.
        guard let probe = try Self.makeEnvironmentProbe() else {
            // Fail rather than skip: silently passing would hide a real regression.
            Issue.record("Could not build the environment probe; the guard is unverified.")
            return
        }
        defer { try? FileManager.default.removeItem(at: probe.deletingLastPathComponent()) }

        let collector = Collector()
        let result = try await ProcessRunner(
            executable: probe,
            arguments: [],
            environment: ["DYLD_INSERT_LIBRARIES": "/nonexistent/evil.dylib"]
        ).run { collector.append($0) }

        // The probe must have run at all — if the variable reached it, dyld would
        // have killed it before main and there would be no output.
        #expect(result.isSuccess, "probe died with exit \(result.exitCode): dyld killed it")
        // Empty brackets: absent, not merely empty.
        #expect(
            collector.text() == "[]",
            "DYLD_INSERT_LIBRARIES leaked to the child: \(collector.text())"
        )
    }

    @Test("A child injected into by its host still runs")
    func childRunsDespiteHostInjection() async throws {
        // End-to-end version of the failure: an unloadable dylib is requested and
        // the child must still start and produce output.
        guard let probe = try Self.makeEnvironmentProbe() else {
            Issue.record("Could not build the environment probe; the guard is unverified.")
            return
        }
        defer { try? FileManager.default.removeItem(at: probe.deletingLastPathComponent()) }

        let collector = Collector()
        let result = try await ProcessRunner(
            executable: probe,
            arguments: [],
            environment: ["DYLD_INSERT_LIBRARIES": "@executable_path/__does_not_exist.dylib"]
        ).run { collector.append($0) }

        #expect(result.isSuccess, "child died with exit \(result.exitCode)")
        #expect(!collector.text().isEmpty, "child produced no output; it was killed before main")
    }

    // MARK: - TERM

    /// Compiles a probe that reports the raw `TERM` it received.
    ///
    /// `/bin/sh` cannot be used to *read* `TERM`: measured, `${TERM-unset}` inside
    /// `sh` reports `dumb` even when the variable is genuinely absent from
    /// `environ`, because the shell supplies its own default. A compiled probe
    /// reading `getenv` is the only honest observer. (Confusingly, `sh` *forwards*
    /// the real environment correctly — it only lies about its own expansion.)
    private static func makeTermProbe() throws -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("term-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("probe.c")
        try """
        #include <stdio.h>
        #include <stdlib.h>
        int main(void) {
            const char *v = getenv("TERM");
            printf("[%s]", v ? v : "ABSENT");
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        let binary = directory.appendingPathComponent("probe")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["clang", "-o", binary.path, source.path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()

        guard compile.terminationStatus == 0,
            FileManager.default.isExecutableFile(atPath: binary.path)
        else { return nil }
        return binary
    }

    @Test("TERM is not passed to the child")
    func termIsStripped() async throws {
        // Xcode sets TERM=dumb for a debugged app. The engine's Spectre.Console
        // progress bar sizes itself from TERM and, told the terminal has no
        // capabilities, throws from its own renderer:
        //
        //   System.ArgumentException: Offset and length were out of bounds…
        //      at Spectre.Console.LiveRenderable.<Render>d__25.MoveNext()
        //
        // Measured on a real download with identical argv: TERM=dumb → exit 134 and
        // 0 bytes; TERM=xterm-256color → exit 0 and 17 MB; TERM absent → exit 0 and
        // 17 MB. Absent is what this strips down to.
        guard let probe = try Self.makeTermProbe() else {
            Issue.record("Could not build the TERM probe; the guard is unverified.")
            return
        }
        defer { try? FileManager.default.removeItem(at: probe.deletingLastPathComponent()) }

        let collector = Collector()
        _ = try await ProcessRunner(
            executable: probe,
            arguments: [],
            environment: ["TERM": "dumb"]
        ).run { collector.append($0) }

        // ABSENT, not empty: Spectre distinguishes a blank TERM from a missing one.
        #expect(
            collector.text() == "[ABSENT]",
            "TERM reached the child as \(collector.text())"
        )
    }

    @Test("A caller cannot accidentally reintroduce TERM")
    func callerSuppliedTermIsAlsoStripped() async throws {
        // The strip happens after the caller's overrides are merged, so even an
        // explicit request cannot put the engine back on the broken path.
        guard let probe = try Self.makeTermProbe() else {
            Issue.record("Could not build the TERM probe; the guard is unverified.")
            return
        }
        defer { try? FileManager.default.removeItem(at: probe.deletingLastPathComponent()) }

        let collector = Collector()
        _ = try await ProcessRunner(
            executable: probe,
            arguments: [],
            environment: ["TERM": "xterm-256color"]
        ).run { collector.append($0) }

        #expect(collector.text() == "[ABSENT]")
    }
}
