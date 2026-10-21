# Tests

Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.

## The unit-test bundle lives inside the host app — do not look for it in Products/Debug

macOS unit tests are hosted by the app, so the built bundle is at:

```
Build/Products/Debug/M3U8Downloader.app/Contents/PlugIns/M3U8DownloaderTests.xctest
```

**Recorded because it produced a wrong conclusion once:** running
`find <DerivedData>/Build/Products/Debug/M3U8DownloaderTests.xctest -name '*.txt'`
returns nothing — not because a resource is missing, but because that path does
not exist. `find` on a non-existent directory prints its error to stderr and an
empty result to stdout, which reads exactly like "the file was not copied". The
earlier note claiming fixtures were *not* being bundled was wrong for this reason.
Verify with the PlugIns path above, and check byte counts rather than mere presence.

## Fixtures are bundled automatically, and the loader must fail loudly

This project uses Xcode 16+ `PBXFileSystemSynchronizedRootGroup`, so every build
phase in `project.pbxproj` is empty and files are picked up from disk by location.
A `.txt` dropped in `M3U8DownloaderTests/Fixtures/` is copied to the bundle's
`Contents/Resources/` with no project edit required (measured: the 6080-byte
capture arrives byte-identical).

`FixtureLoadingProbe.swift` exists because a test that cannot find its input can
still pass. It asserts the fixture's **exact byte count** and the presence of
specific substrings, and asserts that a missing fixture *throws* rather than
yielding empty text — otherwise every parser test would pass against `""`.
Keep that probe passing before trusting anything in `EngineOutputParserTests`.

## `engine-stdout-failed-download.txt` is a real capture; do not tidy it

Byte-for-byte stdout+stderr from an actual engine run, including its ugliest
properties: log records run together without newlines, progress-bar repaints
interleaved mid-record, and `tput:` noise from the engine's exit handler. Those
defects are the entire reason `EngineOutputParser` is not line-based, so
reformatting or hand-editing the file would silently destroy what the tests prove.
Regenerate it by re-running the engine, never by editing.

To reproduce a capture without network access (the engine only needs a manifest it
can reach): write a local `.m3u8`, serve the segments over `127.0.0.1`, and run the
engine with `--no-ansi-color True`. `--skip-download True` exercises parsing and
`meta.json` only; omit it to get progress-bar output.

## 🔴 `engine-stdout-progress.txt` exists because invented token shapes hid a real bug

Second capture, **10522 bytes**: a complete six-segment download, throttled so the
progress bar reports intermediate values. `engine-stdout-failed-download.txt` cannot
cover that — it fails at `0/3`, so every repaint in it reads `0.00%` with the size
column collapsed to `-`.

That gap shipped a defect. The progress tests were written from *hand-made* strings
like `1/3 33.33% -0.00Bps 00:00:07`, which omit the size column entirely — a shape the
engine never emits mid-download. They passed for months while the app showed a garbled
speed (`608.00KB/3.56MB304.00KBps`) and no transferred size at all. **Assert progress
shapes against this fixture, and copy literals out of it rather than composing them.**

Regenerate with a throttled local server:

```bash
# six ~400KB segments in www/, a plain #EXT-X-ENDLIST playlist, python3 -m http.server
env -u TERM "$ENGINE" http://127.0.0.1:8765/local.m3u8 \
  --no-ansi-color True --auto-select True --thread-count 1 \
  --max-speed 300K --save-dir out --save-name cap \
  --ffmpeg-binary-path "$(command -v ffmpeg)" > capture.txt 2>&1
```

`--max-speed` is what makes it usable: the size column only populates on a whole-second
tick, so an unthrottled localhost download finishes before the engine prints one.
`env -u TERM` matches what the app does — see the `TERM=dumb` note in
`Core/AGENTS.md`. Random-byte segments are fine; the ffmpeg merge then fails, which the
capture records as WARN lines, but the download phase is what the fixture is for.

## `engine-stdout-multi-stream.txt`: three bars in one repaint

Third capture, **34286 bytes**: a master playlist with video, audio and a subtitle
rendition, so every repaint carries three rows glued together. Neither other fixture
can show that — both are single-stream — and a single-stream capture is exactly what
let the "last row wins" bug through.

It also captures two shapes only a multi-stream run produces: a queued task reporting
Spectre's default `0/100`, and `Selected streams:` log lines that name a stream just
before the bar's own description, which is what the tempered description pattern has
to survive.

Regenerate it the same way as the progress capture, with a master playlist:

```
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Audio",LANGUAGE="en",URI="audio.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="English",LANGUAGE="en",URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud",SUBTITLES="sub"
video.m3u8
```

plus `--auto-select True --max-speed 250K --thread-count 1`. Give the tracks different
segment counts (4 / 3 / 1 here); equal counts would hide any weighting mistake in the
overall percentage.

## `engine-stdout-failed-verdict.txt`: a failure that exits 0

Fourth capture, **3107 bytes**, and the smallest one that matters most: a download the
engine itself declares failed, which **exits 0**. Reproduced by serving eight segments
and truncating two of them — promise the full `Content-Length`, write a third of the
body, close — so retries are exhausted and the segment-count check fails.

It is the only fixture carrying `ERROR:` records (note: no space before the colon), and
the only one where the `tput` noise is glued directly onto the engine's verdict with no
newline between them. Both of those were parser bugs that made a failing download look
like a silent success.

```bash
# handler: send Content-Length for the full body, then write len//3 and close
env -u TERM "$ENGINE" http://127.0.0.1:8768/trunc.m3u8 \
  --no-ansi-color True --auto-select True --thread-count 2 --download-retry-count 1 \
  --save-dir out --save-name trunc -M format=MP4 \
  --ffmpeg-binary-path "$(command -v ffmpeg)" > capture.txt 2>&1
echo "exit: $?"   # 0, despite `ERROR: Failed`
```

`--download-retry-count 1` keeps it quick; without it each bad segment takes four
attempts a second apart.

## 🔴 An unguarded subscript in a test takes the whole suite down with it

Measured while mutation-checking the log-level fix: `records[2]` in a test that expected
four records found two, trapped, and killed the test host — **18 unrelated
`ProcessRunnerTests` were then reported as failed in 0.000 seconds each**. The mutation
looked far more destructive than it was, and a real regression would read the same way.

The tell is the timing: a test that "fails" in 0.000s alongside a whole other suite did
not run. Compare mapped arrays (`records.map(\.message) == [...]`) instead of indexing,
and use `try #require` rather than `try!` — both fail with a diagnostic instead of
trapping.

## Prove a new test can fail

Mutate the implementation, confirm the test goes red *for the intended reason*,
then restore and re-verify with `md5`. Three mutations that have been used here and
are worth repeating after changes:

- `CommandBuilder`: drop the `!value.isEmpty` guard — `emptyStringsAreOmitted`
  must fail showing `["x", "--save-name", "", ...]`.
- `EngineOutputParser`: make `logRecords` split on `\n` — `allLevels` must fail
  showing all four records merged into one string.
- `ProcessRunner`: replace `StreamDecoder.decode`'s body with
  `return String(data: data, encoding: .utf8)` — `splitMultibyteCharacterSurvives`
  must fail with `text.count → 1696` against an expected `100000`.
- `EngineOutputParser`: restore the pre-fix progress pattern
  (`…%\s*([^\s(]*)(?:\((\d+)\))?\s*-?\s*(ETA)`) — nine tests must fail, among them
  `progressInFlight` and `realCaptureCarriesSpeedAndSize`. Note which ones do **not**:
  `realCaptureProgressAdvances` stays green, because the old pattern did still track
  the percentage. That asymmetry is the evidence for the correction recorded in
  `Core/AGENTS.md`.
- `EngineOutputParser`: drop the `(?!Vid |Aud |Sub )` temper from the description
  pattern — `descriptionDoesNotSwallowLogText`, `multiStreamDescriptions` and
  `realCaptureProgressKeepsLogs` must fail, and *only* those three. This is the
  surgical version; deleting the whole description group instead shifts every capture
  index and fails 21 tests, which proves much less.
- `DownloadJob`: make `record(_:)` assign `streamProgress = [progress]` — the five
  tests in `DownloadJobStreamProgressTests` that cover more than one stream must fail.
  That mutation *is* the bug that was reported, so keep it working.
- `EngineOutputParser`: put the log-prefix pattern back to `LEVEL : ` — five tests must
  fail, `levelSeparatorVariants` and `realCaptureFailedVerdict` among them.
- `EngineOutputParser`: restore `guard !message.isEmpty, !isToolNoise(message)` in
  `logRecords` — `verdictSurvivesToolNoise` and `realCaptureFailedVerdict` must fail,
  because the verdict record disappears.
- `DownloadJob`: drop the `verdict == .failed` branch from `engineOutcome`, leaving the
  exit-code test first — `verdictBeatsExitCode` and `causeIsCarried` must fail. That
  mutation is the "UI said finished for a failed download" bug exactly.

## Forcing a mid-character pipe split: two traps that produce silent false passes

The `StreamDecoder` tests initially passed *with the decoder mutated away*. Both
causes were measured, and both leave a test that looks correct while proving
nothing:

1. **Many small writes never split a character.** A child looping
   `printf '\342\224\201'` writes 3 bytes at a time and the pipe preserves those
   boundaries: measured 28114 reads, **0** split. One large write does split —
   `cat` on a 300 KB file gave 19 reads with **18** cut mid-character, and naive
   per-chunk decoding recovered only 1696 of 100000 characters. So these tests
   stage data in a temp file and `cat` it rather than generating it in a loop.
2. **A repeating unit whose byte length divides the read size never splits.**
   Pipe reads come back in 16384-byte chunks. The original mixed-Unicode test used
   `"下载中━🎬"`, which is exactly **16** bytes — and 16384 = 1024 x 16, so every
   boundary landed neatly between units. Appending one ASCII byte (17 bytes,
   coprime with 16384) makes splits happen. The test now asserts
   `16384 % unit.utf8.count != 0` so this cannot silently regress.

A related self-inflicted failure worth remembering: the same test first hardcoded
`unit.count * 4` when `"下载中━🎬"` is **5** Characters. Derive expectations from
the input (`unit.count * repeats`) instead of hand-counting.

## Never probe `DYLD_*` behaviour through `/bin/sh`

`ProcessRunner` strips `DYLD_INSERT_LIBRARIES` and friends before spawning a
child. The first tests for that guard used `/bin/sh -c 'printf … $DYLD_…'` and
**passed with the stripping mutated away** — a third silent false pass. Two
separate mechanisms hide the difference, both measured:

- SIP-protected system binaries (`/bin/sh`, `/bin/echo`) never see `DYLD_*` at
  all: dyld removes it before the process starts. Verified —
  `DYLD_INSERT_LIBRARIES=/nonexistent/x.dylib /bin/sh -c 'echo $DYLD_INSERT_LIBRARIES'`
  prints empty, whereas the same variable applied to an unprotected binary makes
  dyld terminate it.
- A shell also *forwards* the already-stripped environment, so even
  `sh -c '/path/to/unprotected-probe'` reports empty.

The working approach, used by `makeEnvironmentProbe()`: compile a tiny C binary
into a temp directory with `xcrun clang` and run **that** directly through
`ProcessRunner`. Unprotected and directly spawned, it either reports the variable
or is killed by dyld — either way the guard is actually exercised. With the
stripping removed, those tests fail with
`Result(exitCode: 6, wasTerminatedBySignal: true)`, which is the exact symptom
seen in the app.

Fourth mutation worth repeating: delete the `for key in Self.injectionEnvironmentKeys`
loop in `ProcessRunner.childEnvironment()` — `dyldInjectionIsStripped` and
`childRunsDespiteHostInjection` must both fail with exit 6.


