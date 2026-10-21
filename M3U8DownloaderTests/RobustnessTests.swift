import Foundation
import Testing

@testable import M3U8Downloader

// MARK: - Output split across pipe reads

/// The pipe is read in arbitrary pieces, so any record can arrive cut in two. These tests
/// cut real captures at every offset the budget allows and require the result to be the
/// same as parsing the whole text at once.
struct ChunkAssemblerTests {

    /// Runs `pieces` through an assembler the way the coordinator does (one `feed` per
    /// drain, then `finish`) and parses each released piece on its own.
    private func events(feeding pieces: [String]) -> [EngineOutputParser.Event] {
        var assembler = ChunkAssembler()
        var released: [String] = []
        for piece in pieces {
            if let ready = assembler.feed(piece) { released.append(ready) }
        }
        if let rest = assembler.finish(nil) { released.append(rest) }
        return released.flatMap { EngineOutputParser.events(in: $0) }
    }

    private func logs(_ events: [EngineOutputParser.Event]) -> [EngineOutputParser.LogRecord] {
        events.compactMap {
            if case .log(let record) = $0 { return record }
            return nil
        }
    }

    private func progress(_ events: [EngineOutputParser.Event]) -> [EngineOutputParser.Progress] {
        events.compactMap {
            if case .progress(let reading) = $0 { return reading }
            return nil
        }
    }

    private func split(_ text: String, at offset: Int) -> [String] {
        let index = text.index(text.startIndex, offsetBy: offset)
        return [String(text[..<index]), String(text[index...])]
    }

    @Test("A verdict cut in half still arrives whole")
    func verdictSplitMidWord() {
        let text = "12:15:50.143 ERROR: Segment count check not pass.12:15:50.144 ERROR: Failed"
        let cut = text.count - 3  // "ERROR: Fai" | "led"
        let records = logs(events(feeding: split(text, at: cut)))

        #expect(records.map(\.message) == ["Segment count check not pass.", "Failed"])
        #expect(records.last.flatMap(EngineOutputParser.verdict(in:)) == .failed)
    }

    @Test("Cutting the failed-verdict capture anywhere never changes its records")
    func everyOffsetOfTheVerdictCapture() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-failed-verdict")
        let whole = logs(EngineOutputParser.events(in: text))
        #expect(!whole.isEmpty)

        for offset in 1..<text.count {
            let got = logs(events(feeding: split(text, at: offset)))
            if got != whole {
                Issue.record("cut at \(offset) changed the records: \(got.count) vs \(whole.count)")
                return
            }
        }
    }

    @Test("Cutting every capture at sampled offsets never changes its records or last progress")
    func sampledOffsetsOfAllCaptures() throws {
        for name in [
            "engine-stdout-failed-download", "engine-stdout-progress",
            "engine-stdout-multi-stream",
        ] {
            let text = try EngineOutputParserTests.loadFixture(name)
            let whole = EngineOutputParser.events(in: text)
            let wholeLogs = logs(whole)

            for offset in stride(from: 1, to: text.count, by: 61) {
                let got = events(feeding: split(text, at: offset))
                if logs(got) != wholeLogs {
                    Issue.record("\(name): cut at \(offset) changed the log records")
                    return
                }
                if progress(got) != progress(whole) {
                    Issue.record("\(name): cut at \(offset) changed the progress readings")
                    return
                }
            }
        }
    }

    @Test("Many small pieces give the same records as one big one")
    func manyTinyPieces() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-failed-verdict")
        let whole = logs(EngineOutputParser.events(in: text))

        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 5, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[start..<end]))
            start = end
        }
        #expect(logs(events(feeding: pieces)) == whole)
    }

    @Test("The unfinished last record is held back, then released by an idle tick")
    func idleTickReleases() {
        var assembler = ChunkAssembler()
        #expect(assembler.feed("10:24:55.718 INFO : Parsing streams...") == nil)

        let released = assembler.feed(nil)
        #expect(released == "10:24:55.718 INFO : Parsing streams...")
        #expect(assembler.feed(nil) == nil, "a release must clear the tail")
    }

    @Test("Earlier records are released at once; only the last is held")
    func onlyTheLastIsHeld() throws {
        var assembler = ChunkAssembler()
        let fed = assembler.feed("10:24:55.718 INFO : One10:24:55.719 INFO : Two")
        let ready = try #require(fed)
        #expect(ready == "10:24:55.718 INFO : One")
        #expect(assembler.finish(nil) == "10:24:55.719 INFO : Two")
    }

    @Test("finish releases everything that is left, including the piece passed to it")
    func finishReleasesAll() {
        var assembler = ChunkAssembler()
        _ = assembler.feed("10:24:55.718 ERROR: Fai")
        #expect(assembler.finish("led") == "10:24:55.718 ERROR: Failed")
    }

    @Test("Output with no boundary cannot grow the tail without limit")
    func carryIsCapped() {
        var assembler = ChunkAssembler(maximumCarryBytes: 100)
        let junk = String(repeating: "x", count: 500)
        #expect(assembler.feed(junk) == junk)
        #expect(assembler.feed(nil) == nil, "nothing should be left over")
    }

    @Test("A progress reading is released at once even while a record is unfinished")
    func progressNotFrozenByPendingRecord() throws {
        let token = "Vid Kbps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 0/3 0.00% -0.00Bps --:--:--"
        var assembler = ChunkAssembler()
        let fed = assembler.feed("10:24:55.721 INFO : Start downloading..." + token)
        let ready = try #require(fed)

        let readings = EngineOutputParser.events(in: ready).filter {
            if case .progress = $0 { return true }
            return false
        }
        #expect(readings.count == 1)
        // The record itself is still pending, with the token no longer glued to it.
        #expect(assembler.finish(nil) == "10:24:55.721 INFO : Start downloading...")
    }

    @Test("Progress is not held back behind the last record")
    func progressFlowsPastRecords() throws {
        let text = try EngineOutputParserTests.loadFixture("engine-stdout-progress")
        var assembler = ChunkAssembler()
        let half = text.index(text.startIndex, offsetBy: text.count / 2)
        let fed = assembler.feed(String(text[..<half]))
        let ready = try #require(fed)

        // Most of the first half must be released, not parked in the tail.
        #expect(ready.count > text.count / 4)
        #expect(!EngineOutputParser.events(in: ready).isEmpty)
    }
}

// MARK: - Probe options

@MainActor
struct ProbeOptionsTests {

    private let directory = URL(fileURLWithPath: "/tmp/probe-dir")

    @Test("The probe writes everything under its own directory")
    func redirectsDirectories() {
        var options = DownloadOptions()
        options.basic.saveDirectory = "/Users/me/Movies"
        options.basic.tempDirectory = "/Volumes/Scratch"

        let probe = DownloadCoordinator.probeOptions(from: options, directory: directory)
        #expect(probe.basic.saveDirectory == "/tmp/probe-dir")
        #expect(probe.basic.tempDirectory == "/tmp/probe-dir")
    }

    @Test("meta.json is forced on even if the user turned it off")
    func forcesMetaJSON() {
        var options = DownloadOptions()
        options.advanced.writeMetaJSON = false
        let probe = DownloadCoordinator.probeOptions(from: options, directory: directory)
        #expect(probe.advanced.writeMetaJSON == true)
    }

    @Test("The probe lists streams without downloading and without prompting")
    func nonInteractiveAndSkipping() {
        let probe = DownloadCoordinator.probeOptions(
            from: DownloadOptions(), directory: directory)
        #expect(probe.advanced.skipDownload == true)
        #expect(probe.selection.autoSelect == true)
    }

    @Test("The user's own options survive, so a proxy or header still reaches the manifest")
    func keepsTheRest() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.network.customProxy = "http://127.0.0.1:8080"
        options.network.threadCount = 4
        let probe = DownloadCoordinator.probeOptions(from: options, directory: directory)

        #expect(probe.input == options.input)
        #expect(probe.network.customProxy == "http://127.0.0.1:8080")
        #expect(probe.network.threadCount == 4)
    }
}

// MARK: - Whitespace in values

struct ArgumentTrimmingTests {

    @Test("A padded URL is trimmed before it reaches the engine")
    func trimsInput() {
        var options = DownloadOptions()
        options.input = "  https://example.com/a.m3u8\n"
        #expect(CommandBuilder.arguments(for: options).first == "https://example.com/a.m3u8")
    }

    @Test("A padded path or name is trimmed")
    func trimsValues() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.basic.saveDirectory = " /Users/me/Movies "
        options.basic.saveName = "Episode 1 "

        let argv = CommandBuilder.arguments(for: options)
        #expect(argv.contains("/Users/me/Movies"))
        #expect(argv.contains("Episode 1"))
    }

    @Test("A whitespace-only value counts as unset and emits no flag")
    func whitespaceOnlyIsUnset() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.basic.saveName = "   "

        #expect(!CommandBuilder.arguments(for: options).contains("--save-name"))
    }

    @Test("Interior spaces are preserved")
    func keepsInteriorSpaces() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.basic.saveName = "My Show S01"
        #expect(CommandBuilder.arguments(for: options).contains("My Show S01"))
    }
}

// MARK: - Extra arguments round trip

struct ExtraArgumentsRoundTripTests {

    private func roundTrip(_ arguments: [String]) -> [String] {
        ExtraArgumentsField.tokenize(ExtraArgumentsField.render(arguments))
    }

    @Test("An argument with a space survives being shown and parsed again")
    func spaceSurvives() {
        let arguments = ["-H", "User-Agent: My Browser 1.0"]
        #expect(roundTrip(arguments) == arguments)
    }

    @Test("Plain arguments render unchanged")
    func plainUnchanged() {
        #expect(
            ExtraArgumentsField.render(["--custom-range", "00:00-10:00"])
                == "--custom-range 00:00-10:00")
    }

    @Test("Quote characters inside an argument survive")
    func quotesSurvive() {
        for arguments in [
            ["it's"], ["say \"hi\""], ["a'b\"c d"], ["\""], ["'"], ["x", "a b", "c\"d"],
        ] {
            #expect(roundTrip(arguments) == arguments, "\(arguments)")
        }
    }

    @Test("Whatever the user types is stable after one trip through the field")
    func typedTextIsStable() {
        for typed in [
            "-H \"A B\"", "--x 'it''s'", "\"it's\" plain", "a\"b c\"d", "  spaced   out  ",
        ] {
            let once = ExtraArgumentsField.tokenize(typed)
            #expect(roundTrip(once) == once, "\(typed)")
        }
    }

    @Test("No arguments render as an empty field")
    func emptyRendersEmpty() {
        #expect(ExtraArgumentsField.render([]) == "")
    }
}

// MARK: - Through the coordinator, with a stand-in engine

/// The unit tests above prove the assembler; these prove the coordinator actually uses it.
/// Wiring is exactly what a unit test of the parts cannot see, and a missing hookup passes
/// every one of them.
@MainActor
struct CoordinatorSplitRecordTests {

    /// An executable that behaves like the engine in the one way that matters here: it
    /// writes each record in two separate writes with a pause between, so the coordinator's
    /// periodic drain lands between the halves some of the time.
    private func makeFakeEngine(records: Int) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var script = "#!/bin/sh\n"
        for number in 1...records {
            let stamp = String(format: "12:00:%02d.000", number)
            script += "printf '\(stamp) INFO : Record \(number)'\n"
            script += "sleep 0.05\n"
            script += "printf ' of \(records)'\n"
        }
        // The verdict itself is split, and the process still exits 0, like the real engine.
        script += "printf '12:01:00.000 ERROR: Fai'\nsleep 0.05\nprintf 'led'\nexit 0\n"

        let url = directory.appendingPathComponent("engine.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory)
    }

    @Test("Records split across reads arrive whole, and a split verdict still fails the job")
    func splitRecordsThroughTheCoordinator() async throws {
        let records = 20
        let (engine, directory) = try makeFakeEngine(records: records)
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = DownloadCoordinator(
            engineStatus: .success(.init(url: engine, source: .userOverride)),
            ffmpegStatus: .failure(.notFound(.ffmpeg)))

        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.selection.autoSelect = true
        options.basic.saveDirectory = directory.path
        let id = coordinator.addJob(options: options)
        coordinator.startJob(id: id)

        let deadline = Date().addingTimeInterval(30)
        func job() -> DownloadJob? { coordinator.jobs.first { $0.id == id } }
        while job()?.state.isTerminal != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let finished = try #require(job())
        guard case .failed = finished.state else {
            Issue.record("expected a failed job, got \(finished.state)")
            return
        }

        let messages = finished.log.records.map(\.message)
        for number in 1...records {
            #expect(
                messages.contains("Record \(number) of \(records)"),
                "record \(number) arrived damaged; log was \(messages)")
        }
        #expect(finished.engineVerdict == .failed)
    }
}

// MARK: - Stopping a process and everything it started

/// Real processes, for the same reason as `ProcessRunnerTests`: what is under test is how the
/// OS delivers signals and closes pipes.
///
/// Every script here ends by itself within seconds. If a mutation or a regression stops the
/// runner from killing it, the test must fail rather than leave a runaway shell behind.
struct ProcessTerminationTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = false
        func set() {
            lock.lock()
            seen = true
            lock.unlock()
        }
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pid-\(UUID().uuidString)")
    }

    private func isGone(_ pid: pid_t, within seconds: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    @Test("Cancelling also stops a grandchild, and does not wait for it")
    func cancelKillsGrandchildren() async throws {
        let pidFile = scratchFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let up = Flag()

        // `sleep 60 &` then `wait` keeps the shell from exec-ing it, so the sleep really is
        // a grandchild — and it inherits our pipes, so EOF never comes while it lives.
        let script = "sleep 60 & echo $! > '\(pidFile.path)'; printf up; wait"
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            terminationGrace: 1)
        let started = Date()
        let task = Task { try await runner.run { _ in up.set() } }

        while !up.isSet, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(up.isSet, "child never started")
        try await Task.sleep(for: .milliseconds(100))  // let the pid file be written

        task.cancel()
        _ = try await task.value
        #expect(Date().timeIntervalSince(started) < 10, "cancel waited on the grandchild")

        let text = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(text))
        let gone = try await isGone(pid, within: 3)
        if !gone { kill(pid, SIGKILL) }  // never leave the stray behind
        #expect(gone, "the grandchild survived the cancel")
    }

    @Test("A process that ignores SIGTERM is killed after the grace period")
    func stubbornProcessIsKilled() async throws {
        let up = Flag()
        // `trap ''` makes the shell, and every child it starts, ignore SIGTERM. The loop is
        // bounded so a failure ends the script on its own after ten seconds.
        let script =
            "trap '' TERM; printf up; i=0; while [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done"
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            terminationGrace: 0.5)
        let started = Date()
        let task = Task { try await runner.run { _ in up.set() } }

        while !up.isSet, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(up.isSet, "child never started")

        let cancelledAt = Date()
        task.cancel()
        let result = try await task.value
        let took = Date().timeIntervalSince(cancelledAt)

        #expect(took < 5, "SIGTERM was ignored and nothing escalated (took \(took)s)")
        #expect(result.wasTerminatedBySignal)
        #expect(!result.isSuccess)
    }

    @Test("A process that exits on SIGTERM is not held for the grace period")
    func cooperativeProcessExitsPromptly() async throws {
        let up = Flag()
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf up; sleep 30 & wait"], terminationGrace: 20)
        let started = Date()
        let task = Task { try await runner.run { _ in up.set() } }
        while !up.isSet, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }

        let cancelledAt = Date()
        task.cancel()
        _ = try await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 5, "waited out the grace period")
    }

    @Test("The tree of a process includes its descendants, and a pid alone is not an identity")
    func treeMembers() async throws {
        let up = Flag()
        let runner = ProcessRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & sleep 30 & printf up; wait"], terminationGrace: 1)
        let task = Task { try await runner.run { _ in up.set() } }
        let started = Date()
        while !up.isSet, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))

        let own = ProcessTree.members(rootedAt: getpid())
        #expect(own.first?.pid == getpid())
        // The shell and its two sleeps are among this test host's descendants.
        #expect(own.count >= 3, "found \(own.count) members")
        if let first = own.first {
            #expect(ProcessTree.isAlive(first))
            let stale = ProcessTree.Member(
                pid: first.pid, startSeconds: first.startSeconds + 1,
                startMicroseconds: first.startMicroseconds)
            #expect(!ProcessTree.isAlive(stale), "a reused pid must not match")
        }

        task.cancel()
        _ = try await task.value
    }

    @Test("A pid that does not exist has no members")
    func missingRoot() {
        #expect(ProcessTree.members(rootedAt: 999_999).isEmpty)
    }
}

// MARK: - Job lifecycle through the coordinator

/// Stop, quit and the one-job-at-a-time limit, driven through a stand-in engine. All of it is
/// coordination between tasks and processes, so only running the real thing shows it works.
@MainActor
struct CoordinatorLifecycleTests {

    /// A stand-in engine that runs `body` as a shell script. The directory is the caller's
    /// to remove.
    private func makeEngine(_ body: String) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("engine.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory)
    }

    private func makeCoordinator(engine: URL) -> DownloadCoordinator {
        DownloadCoordinator(
            engineStatus: .success(.init(url: engine, source: .userOverride)),
            ffmpegStatus: .failure(.notFound(.ffmpeg)))
    }

    /// A download job that skips the track prompt, writing under `directory`.
    private func addDownload(
        to coordinator: DownloadCoordinator, in directory: URL, autoSelect: Bool = true
    ) -> UUID {
        var options = DownloadOptions()
        options.input = "https://example.com/\(UUID().uuidString).m3u8"
        options.selection.autoSelect = autoSelect ? true : nil
        options.basic.saveDirectory = directory.path
        return coordinator.addJob(options: options)
    }

    private func job(_ id: UUID, in coordinator: DownloadCoordinator) -> DownloadJob? {
        coordinator.jobs.first { $0.id == id }
    }

    private func wait(
        _ seconds: TimeInterval = 20, until condition: () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func isGone(_ pid: pid_t) async throws -> Bool {
        try await wait(3) { kill(pid, 0) != 0 && errno == ESRCH }
    }

    // MARK: Stopping

    @Test("Stop shows as stopping, ends as stopped, and takes the whole process tree with it")
    func stopKillsTheTree() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let (engine, directory) = try makeEngine(
            "sleep 60 & echo $! > '\(pidFile.path)'; printf '12:00:00.000 INFO : up'; wait")
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = makeCoordinator(engine: engine)
        let id = addDownload(to: coordinator, in: directory)
        coordinator.startJob(id: id)

        let up = try await wait {
            job(id, in: coordinator)?.log.records.contains { $0.message == "up" } == true
        }
        #expect(up, "the stand-in engine never started")
        try await Task.sleep(for: .milliseconds(150))  // let the pid file be written

        coordinator.cancelJob(id: id)
        #expect(job(id, in: coordinator)?.isStopping == true)
        #expect(coordinator.hasActiveWork, "the slot must stay busy until the process is gone")

        let stopped = try await wait { job(id, in: coordinator)?.state == .cancelled }
        #expect(stopped, "state was \(String(describing: job(id, in: coordinator)?.state))")
        #expect(job(id, in: coordinator)?.isStopping == false)
        #expect(!coordinator.hasActiveWork)

        let pid = try #require(
            pid_t(
                try String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        let gone = try await isGone(pid)
        if !gone { kill(pid, SIGKILL) }
        #expect(gone, "the engine's own child survived the stop")
    }

    @Test("stopAllAndWait returns only once the processes are gone")
    func stopAllWaits() async throws {
        let (engine, directory) = try makeEngine(
            "printf '12:00:00.000 INFO : up'; sleep 60 & wait")
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = makeCoordinator(engine: engine)
        let id = addDownload(to: coordinator, in: directory)
        coordinator.startJob(id: id)
        let up = try await wait {
            job(id, in: coordinator)?.log.records.contains { $0.message == "up" } == true
        }
        #expect(up)

        await coordinator.stopAllAndWait(timeout: .seconds(15))

        #expect(!coordinator.hasActiveWork)
        #expect(job(id, in: coordinator)?.state == .cancelled)
    }

    @Test("With nothing running there is nothing to wait for")
    func stopAllWhenIdle() async {
        let coordinator = DownloadCoordinator(
            engineStatus: .failure(.notFound(.engine)),
            ffmpegStatus: .failure(.notFound(.ffmpeg)))
        #expect(!coordinator.hasActiveWork)
        await coordinator.stopAllAndWait()
        #expect(!coordinator.hasActiveWork)
    }

    // MARK: One at a time

    @Test("A second start waits for the first and then runs by itself")
    func secondJobWaitsThenRuns() async throws {
        let (engine, directory) = try makeEngine(
            "sleep 0.6; printf '12:00:00.000 INFO : Done'")
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = makeCoordinator(engine: engine)
        let first = addDownload(to: coordinator, in: directory)
        let second = addDownload(to: coordinator, in: directory)
        coordinator.startJob(id: first)
        coordinator.startJob(id: second)

        #expect(job(first, in: coordinator)?.state.isRunning == true)
        #expect(job(second, in: coordinator)?.state == .queued)
        #expect(job(second, in: coordinator)?.isWaitingForSlot == true)

        let finished = try await wait {
            job(second, in: coordinator)?.state == .succeeded
        }
        #expect(finished, "state was \(String(describing: job(second, in: coordinator)?.state))")

        let firstEnded = try #require(job(first, in: coordinator)?.finishedAt)
        let secondStarted = try #require(job(second, in: coordinator)?.startedAt)
        #expect(secondStarted >= firstEnded, "the two jobs overlapped")
        #expect(job(second, in: coordinator)?.isWaitingForSlot == false)
    }

    @Test("A job cancelled while waiting never starts")
    func cancelledWaiterStaysQueued() async throws {
        let (engine, directory) = try makeEngine(
            "sleep 0.5; printf '12:00:00.000 INFO : Done'")
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = makeCoordinator(engine: engine)
        let first = addDownload(to: coordinator, in: directory)
        let second = addDownload(to: coordinator, in: directory)
        coordinator.startJob(id: first)
        coordinator.startJob(id: second)
        coordinator.cancelJob(id: second)
        #expect(job(second, in: coordinator)?.isWaitingForSlot == false)

        let done = try await wait { job(first, in: coordinator)?.state == .succeeded }
        #expect(done)
        try await Task.sleep(for: .milliseconds(300))
        #expect(job(second, in: coordinator)?.state == .queued, "it started anyway")
    }

    @Test("A removed waiting job never starts")
    func removedWaiterNeverStarts() async throws {
        let (engine, directory) = try makeEngine(
            "sleep 0.4; printf '12:00:00.000 INFO : Done'")
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = makeCoordinator(engine: engine)
        let first = addDownload(to: coordinator, in: directory)
        let second = addDownload(to: coordinator, in: directory)
        coordinator.startJob(id: first)
        coordinator.startJob(id: second)
        coordinator.removeJob(id: second)

        let done = try await wait { job(first, in: coordinator)?.state == .succeeded }
        #expect(done)
        #expect(job(second, in: coordinator) == nil)
        #expect(!coordinator.hasActiveWork)
    }

    @Test("A failed stream probe frees the slot")
    func failedProbeFreesTheSlot() async throws {
        // The probe's failure path used to return without releasing the job's registration;
        // with a one-job limit that would hold the only slot forever.
        let (engine, directory) = try makeEngine("printf '12:00:00.000 ERROR: Failed'")
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = makeCoordinator(engine: engine)
        let probing = addDownload(to: coordinator, in: directory, autoSelect: false)
        coordinator.startJob(id: probing)

        let failed = try await wait {
            if case .failed = job(probing, in: coordinator)?.state { return true }
            return false
        }
        #expect(failed)
        #expect(!coordinator.hasActiveWork, "the failed probe is still holding the slot")

        let next = addDownload(to: coordinator, in: directory)
        coordinator.startJob(id: next)
        #expect(job(next, in: coordinator)?.isWaitingForSlot == false)
        _ = try await wait { job(next, in: coordinator)?.state.isTerminal == true }
    }
}

// MARK: - Engine log location

@MainActor
struct EngineLogLocationTests {

    @Test("The engine's log goes under the user's Library/Logs, not the app bundle")
    func defaultLogPath() throws {
        let prepared = DownloadCoordinator.prepared(DownloadOptions(), ffmpegPath: nil)
        let path = try #require(prepared.advanced.logFilePath)

        #expect(path.hasSuffix("/Library/Logs/M3U8Downloader/engine.log"), Comment(rawValue: path))
        #expect(!path.contains(".app/"), "must not point into an app bundle")
    }

    @Test("A path the user chose is respected")
    func userPathWins() {
        var options = DownloadOptions()
        options.advanced.logFilePath = "/tmp/mine.log"
        let prepared = DownloadCoordinator.prepared(options, ffmpegPath: nil)
        #expect(prepared.advanced.logFilePath == "/tmp/mine.log")
    }

    @Test("Turning logging off is respected: no path is added")
    func noLogWins() {
        var options = DownloadOptions()
        options.advanced.noLog = true
        let prepared = DownloadCoordinator.prepared(options, ffmpegPath: nil)
        #expect(prepared.advanced.logFilePath == nil)
    }

    @Test("Explicitly leaving logging on still gets the app's path")
    func noLogFalseGetsPath() {
        var options = DownloadOptions()
        options.advanced.noLog = false
        let prepared = DownloadCoordinator.prepared(options, ffmpegPath: nil)
        #expect(prepared.advanced.logFilePath != nil)
    }

    @Test("The path reaches the engine's argv")
    func reachesArgv() {
        let prepared = DownloadCoordinator.prepared(DownloadOptions(), ffmpegPath: nil)
        let argv = CommandBuilder.arguments(for: prepared)
        let flag = argv.firstIndex(of: "--log-file-path")
        #expect(flag != nil)
        if let flag, flag + 1 < argv.count {
            #expect(argv[flag + 1].hasSuffix("engine.log"))
        }
    }
}

// MARK: - ffmpeg failures

struct FFmpegOutputTests {

    @Test("Real ffmpeg failure lines are recognised as errors")
    func errorLines() {
        for line in [
            "in.mp4: No such file or directory",
            "in.mp4: Invalid data found when processing input",
            "Error opening input file in.mp4.",
            "File 'out.mp4' already exists. Not overwriting - exiting",
            "[mov,mp4,m4a,3gp,3g2,mj2 @ 0x1234] moov atom not found",
            "Could not write header for output file #0",
            "out.mp4: Permission denied",
            "Conversion failed!",
        ] {
            #expect(FFmpegOutput.level(for: line) == .error, "\(line)")
        }
    }

    @Test("Progress, stream and banner lines are not errors")
    func quietLines() {
        for line in [
            "ffmpeg version 7.1 Copyright (c) 2000-2024 the FFmpeg developers",
            "  configuration: --prefix=/opt/homebrew --enable-gpl --disable-error-resilience",
            "  libavutil      59. 39.100 / 59. 39.100",
            // The input's own metadata is printed indented, and a title can say anything.
            "    title           : An Error of Judgement",
            "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'in.mp4':",
            "    Stream #0:0[0x1](und): Video: h264, yuv420p, 1920x1080",
            "Output #0, mp4, to 'out.mp4':",
            "frame=  240 fps=0.0 q=-1.0 Lsize=    1024kB time=00:00:10.00 bitrate= 838.9kbits/s",
        ] {
            #expect(FFmpegOutput.level(for: line) == .info, "\(line)")
        }
    }

    @Test("The closing line is generic, and nothing else is")
    func genericFailure() {
        #expect(FFmpegOutput.isGenericFailure("Conversion failed!"))
        #expect(FFmpegOutput.isGenericFailure("  Conversion failed!\n"))
        #expect(!FFmpegOutput.isGenericFailure("Error opening input file in.mp4."))
    }

    @Test("The reason quoted is the cause, not ffmpeg's closing line")
    func reasonSkipsClosingLine() {
        var job = DownloadJob(metadata: MetadataOptions())
        for (level, message) in [
            (EngineOutputParser.Level.info, "Input #0, mov,mp4"),
            (.error, "in.mp4: Invalid data found when processing input"),
            (.error, "Conversion failed!"),
        ] {
            job.log.append(.init(timestamp: "12:00:00.000", level: level, message: message))
        }
        #expect(job.lastErrorMessage == "in.mp4: Invalid data found when processing input")
    }

    @Test("With only the closing line there is still something to show")
    func onlyClosingLine() {
        var job = DownloadJob(metadata: MetadataOptions())
        job.log.append(
            .init(timestamp: "12:00:00.000", level: .error, message: "Conversion failed!"))
        // Nothing better exists; the caller falls back to the exit code.
        #expect(job.lastErrorMessage == nil)
    }
}

/// A failed or stopped metadata pass, through the coordinator with a stand-in ffmpeg.
@MainActor
struct MetadataPartialOutputTests {

    private func makeFFmpeg(_ body: String) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-ffmpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ffmpeg.sh")
        // The output path is ffmpeg's last argument.
        let script = "#!/bin/sh\nfor a; do out=\"$a\"; done\n" + body + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory)
    }

    private func makeCoordinator(ffmpeg: URL) -> DownloadCoordinator {
        DownloadCoordinator(
            engineStatus: .failure(.notFound(.engine)),
            ffmpegStatus: .success(.init(url: ffmpeg, source: .userOverride)))
    }

    /// Input and output paths in `directory`; the input exists, the output does not yet.
    private func addJob(_ coordinator: DownloadCoordinator, in directory: URL) throws -> (
        id: UUID, output: URL
    ) {
        let input = directory.appendingPathComponent("in.mp4")
        try Data("media".utf8).write(to: input)
        let output = directory.appendingPathComponent("out.mp4")
        var metadata = MetadataOptions()
        metadata.inputPath = input.path
        metadata.outputPath = output.path
        return (coordinator.addMetadataJob(metadata: metadata), output)
    }

    private func wait(
        _ seconds: TimeInterval = 20, until condition: () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("A failed pass removes the half-written output and says why")
    func failureCleansUpAndExplains() async throws {
        let (ffmpeg, directory) = try makeFFmpeg(
            "printf partial > \"$out\"; echo 'in.mp4: Invalid data found when processing input' >&2; echo 'Conversion failed!' >&2; exit 1"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(ffmpeg: ffmpeg)
        let (id, output) = try addJob(coordinator, in: directory)

        coordinator.startJob(id: id)
        let done = try await wait { coordinator.jobs.first?.state.isTerminal == true }
        #expect(done)

        guard case .failed(let failure) = coordinator.jobs.first?.state else {
            Issue.record(
                "expected failure, got \(String(describing: coordinator.jobs.first?.state))")
            return
        }
        #expect(failure.message.contains("Invalid data found"), Comment(rawValue: failure.message))
        #expect(!FileManager.default.fileExists(atPath: output.path), "the partial file was left")
    }

    @Test("A retry after a failure succeeds instead of tripping over the leftover file")
    func retryAfterFailure() async throws {
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("flag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: flag) }
        // Like ffmpeg without -y: refuses an existing output; fails the first time only.
        let (ffmpeg, directory) = try makeFFmpeg(
            """
            if [ -e "$out" ]; then echo "File '$out' already exists. Not overwriting - exiting" >&2; exit 1; fi
            printf partial > "$out"
            if [ -e '\(flag.path)' ]; then exit 0; fi
            touch '\(flag.path)'; echo 'Error opening input' >&2; exit 1
            """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(ffmpeg: ffmpeg)
        let (id, output) = try addJob(coordinator, in: directory)

        coordinator.startJob(id: id)
        let failed = try await wait {
            if case .failed = coordinator.jobs.first?.state { return true }
            return false
        }
        #expect(failed)

        coordinator.startJob(id: id)
        let succeeded = try await wait { coordinator.jobs.first?.state == .succeeded }
        #expect(
            succeeded,
            Comment(rawValue: "retry ended as \(String(describing: coordinator.jobs.first?.state))")
        )
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("A stopped pass removes its partial output")
    func cancelCleansUp() async throws {
        let (ffmpeg, directory) = try makeFFmpeg(
            "printf partial > \"$out\"; echo 'Input #0' >&2; sleep 60 & wait")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(ffmpeg: ffmpeg)
        let (id, output) = try addJob(coordinator, in: directory)

        coordinator.startJob(id: id)
        let started = try await wait { FileManager.default.fileExists(atPath: output.path) }
        #expect(started)

        coordinator.cancelJob(id: id)
        let stopped = try await wait { coordinator.jobs.first?.state == .cancelled }
        #expect(stopped)
        #expect(!FileManager.default.fileExists(atPath: output.path), "the partial file was left")
    }

    @Test("A file that was already there is never deleted, even when the pass fails")
    func existingOutputIsKept() async throws {
        let (ffmpeg, directory) = try makeFFmpeg(
            "echo \"File '$out' already exists. Not overwriting - exiting\" >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(ffmpeg: ffmpeg)
        let (id, output) = try addJob(coordinator, in: directory)
        try Data("precious".utf8).write(to: output)

        coordinator.startJob(id: id)
        let done = try await wait { coordinator.jobs.first?.state.isTerminal == true }
        #expect(done)

        #expect(try String(contentsOf: output, encoding: .utf8) == "precious")
    }

    @Test("A successful pass keeps its output")
    func successKeepsOutput() async throws {
        let (ffmpeg, directory) = try makeFFmpeg("printf done > \"$out\"; exit 0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(ffmpeg: ffmpeg)
        let (id, output) = try addJob(coordinator, in: directory)

        coordinator.startJob(id: id)
        let done = try await wait { coordinator.jobs.first?.state == .succeeded }
        #expect(done)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

// MARK: - Save folder

struct TildeExpansionTests {

    private let home = NSHomeDirectory()

    @Test("A leading tilde becomes the home directory")
    func expands() {
        #expect(OutputLocator.expandingTilde("~") == home)
        #expect(OutputLocator.expandingTilde("~/Movies") == home + "/Movies")
    }

    @Test("Anything else is left exactly as typed")
    func leavesOthers() {
        for path in ["/Users/me/Movies", "relative/dir", "a~b", "/tmp/~/x", "~someone/x", ""] {
            #expect(OutputLocator.expandingTilde(path) == path, "\(path)")
        }
    }

    @Test("The engine is given the expanded folder, not a literal tilde")
    func reachesTheEngine() {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.basic.saveDirectory = "~/Movies"
        options.basic.tempDirectory = "~/Scratch"

        let argv = CommandBuilder.arguments(for: options)
        #expect(argv.contains(home + "/Movies"))
        #expect(argv.contains(home + "/Scratch"))
        #expect(!argv.contains("~/Movies"))
    }

    @Test("The folder we look in agrees with the one the engine is given")
    func locatorAgrees() {
        // `URL` expands the tilde on its own, so this holds without our help; it is here to
        // catch the two ever disagreeing, not to prove `expandingTilde`.
        #expect(OutputLocator.directory(saveDirectory: "~/Movies")?.path == home + "/Movies")
    }
}

@MainActor
struct SaveFolderTests {

    private func makeEngine(_ body: String) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("engine.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory)
    }

    private func wait(
        _ seconds: TimeInterval = 20, until condition: () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func addJob(_ coordinator: DownloadCoordinator, saveDirectory: String) -> UUID {
        var options = DownloadOptions()
        options.input = "https://example.com/a.m3u8"
        options.selection.autoSelect = true
        options.basic.saveDirectory = saveDirectory
        return coordinator.addJob(options: options)
    }

    @Test("A save folder that does not exist yet is created, and the download runs")
    func missingFolderIsCreated() async throws {
        let (engine, scratch) = try makeEngine("printf '12:00:00.000 INFO : Done'")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let target = scratch.appendingPathComponent("new/nested")

        let coordinator = DownloadCoordinator(
            engineStatus: .success(.init(url: engine, source: .userOverride)),
            ffmpegStatus: .failure(.notFound(.ffmpeg)))
        let id = addJob(coordinator, saveDirectory: target.path)
        coordinator.startJob(id: id)

        let done = try await wait { coordinator.jobs.first?.state == .succeeded }
        #expect(done, "state was \(String(describing: coordinator.jobs.first?.state))")
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("An unusable save folder is reported as such, without starting the engine")
    func unusableFolderIsExplained() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ran-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let (engine, scratch) = try makeEngine("touch '\(marker.path)'")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let coordinator = DownloadCoordinator(
            engineStatus: .success(.init(url: engine, source: .userOverride)),
            ffmpegStatus: .failure(.notFound(.ffmpeg)))
        // A path beneath a regular file can never be created.
        let id = addJob(coordinator, saveDirectory: "/dev/null/sub")
        coordinator.startJob(id: id)

        guard case .failed(let failure) = coordinator.jobs.first(where: { $0.id == id })?.state
        else {
            Issue.record("expected an immediate failure")
            return
        }
        #expect(failure.message.contains("save folder"), Comment(rawValue: failure.message))
        #expect(failure.message.contains("/dev/null/sub"))
        #expect(!failure.message.contains("Could not start"), "must not blame the engine")

        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the engine was started")
        #expect(!coordinator.hasActiveWork)
    }
}

// MARK: - Long labels and pathological runs (the freeze)

/// The window froze after a long download. Real labels were longer than the progress pattern
/// allowed, so each repaint left residue that the assembler carried and re-scanned, with a
/// pattern that is quadratic in the length of a whitespace run.
struct LongLabelFreezeTests {

    private static let bar = String(repeating: "━", count: 30)
    private static let videoLabel = "Vid 640x360 | 657 Kbps | 29.97 | hvc1.2.20000000.H120.B0 | PQ"
    private static let describedAudio =
        "Aud audio-stereo-aac-128 | English Audio Descriptions | en | 2CH"

    /// One repaint of every row, shaped like the real run that froze: labels copied from the
    /// engine's own log of it, padded columns, an RTL and a CJK subtitle name.
    private static func repaint(percent: Int) -> String {
        var rows = [
            "\(videoLabel) \(bar)  \(percent)/100 \(percent).00% 12.30MB/79.00MB1.20MBps00:01:23",
            "Aud audio-stereo-aac-128 | English | en | 2CH \(bar) 0/100 0.00%      -     -  --:--:--",
            "\(describedAudio) \(bar) 0/100 0.00%      -     -  --:--:--",
        ]
        for name in [
            "ar | العربية", "de | Deutsch", "en | English", "ja | 日本語", "zh-TW | 繁體中文 (台灣)",
        ] {
            rows.append("Sub subs | \(name)     \(bar) 0/100 0.00%      -     -  --:--:--")
        }
        return rows.joined()
    }

    @Test("A label of 60+ characters is read whole, not cut at 60")
    func longLabelsAreWhole() {
        #expect(Self.videoLabel.count > 60 && Self.describedAudio.count > 60)

        let labels = Set(
            EngineOutputParser.events(in: Self.repaint(percent: 5)).compactMap {
                event -> String? in
                if case .progress(let reading) = event { return reading.streamDescription }
                return nil
            })
        #expect(labels.contains(Self.videoLabel))
        #expect(labels.contains(Self.describedAudio), "labels: \(labels.sorted())")
    }

    @Test("Hundreds of repaints leave a small carry, not a growing one")
    func carryStaysSmall() {
        var assembler = ChunkAssembler()
        _ = assembler.feed("10:03:38.680 INFO : Start downloading..." + Self.videoLabel)

        let started = Date()
        for tick in 0..<600 { _ = assembler.feed(Self.repaint(percent: tick % 100)) }
        let elapsed = Date().timeIntervalSince(started)

        // Before the fix this grew by about 350 bytes per tick, to 200 KB.
        #expect(assembler.carriedBytes < 2_000, "the carry reached \(assembler.carriedBytes)")
        #expect(elapsed < 5, "600 repaints took \(elapsed)s")
    }

    @Test("A label longer than any pattern can match still cannot grow the carry without bound")
    func absurdLabelIsCapped() {
        let absurd = "Aud " + String(repeating: "x | ", count: 100) + "tail"
        let row = "\(absurd) \(Self.bar) 0/100 0.00%      -     -  --:--:--"
        var assembler = ChunkAssembler()
        _ = assembler.feed("10:03:38.680 INFO : Start downloading...")

        let started = Date()
        for _ in 0..<400 { _ = assembler.feed(row) }
        #expect(assembler.carriedBytes <= 16 * 1024 + row.utf8.count)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("Long runs of whitespace, bars and digits are scanned in linear time")
    func pathologicalRuns() {
        // 40 000 characters: the unpatched pattern needed about a minute for the spaces alone.
        let size = 40_000
        let inputs = [
            "spaces": String(repeating: " ", count: size),
            "spaces after a percent": "4/4 100.00%" + String(repeating: " ", count: size) + "x",
            "bars": String(repeating: "━", count: size),
            "bars then spaces": String(repeating: "━", count: 30)
                + String(repeating: " ", count: size),
            "digits": String(repeating: "1", count: size),
        ]
        for (name, text) in inputs {
            let started = Date()
            _ = EngineOutputParser.events(in: text)
            var assembler = ChunkAssembler()
            _ = assembler.feed(text)
            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < 2, "\(name) took \(elapsed)s")
        }
    }

    @Test("Ordinary text passes through run compaction unchanged")
    func compactionLeavesNormalTextAlone() {
        for text in [
            "10:24:55.718 INFO : Parsing streams...",
            Self.repaint(percent: 42),
            "Vid 640x360 | 800 Kbps \(Self.bar)   0/4 0.00% -0.00Bps --:--:--",
            "id: 12345678901234567890",  // 20 digits, below the cap
        ] {
            #expect(EngineOutputParser.compactingRuns(text) == text)
        }
    }

    @Test("Runs beyond the caps are cut, and nothing else is")
    func compactionCutsRuns() {
        let spaces = EngineOutputParser.compactingRuns(
            "a" + String(repeating: " ", count: 100) + "b")
        #expect(spaces == "a" + String(repeating: " ", count: 16) + "b")

        let bars = EngineOutputParser.compactingRuns(String(repeating: "━", count: 200))
        #expect(bars.count == 64)

        let digits = EngineOutputParser.compactingRuns(String(repeating: "7", count: 100))
        #expect(digits.count == 24)

        // A different kind of character resets the count.
        let mixed = EngineOutputParser.compactingRuns(
            String(repeating: " ", count: 10) + "x" + String(repeating: " ", count: 10))
        #expect(mixed.count == 21)
    }
}
