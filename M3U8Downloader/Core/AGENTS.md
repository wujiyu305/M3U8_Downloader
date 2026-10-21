# Core layer

Pure, UI-free logic: locating tools, modelling engine options, building argument
vectors. Called from background contexts, so nothing here may be main-actor bound.

## Every declaration here must be explicitly `nonisolated`

The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a new
type added here is implicitly main-actor isolated. That produces
"Main actor-isolated conformance ... cannot be used in nonisolated context; this is
an error in the Swift 6 language mode" warnings at every call site — the build
still succeeds today, so it is easy to add a file and not notice. Mark top-level
`enum`/`struct` declarations, and any helper extensions, `nonisolated`. The
MainActor default is kept deliberately for the SwiftUI layer; do not change it
project-wide to silence this.

## The engine CLI contract lives in the submodule, not in docs

Option names, defaults and enum spellings are read from
`external/N_m3u8DL-RE/src/N_m3u8DL-RE/CommandLine/CommandInvoker.cs` and the
`Enum/` directory. When the submodule is bumped, re-derive them there rather than
trusting these notes or the upstream README.

Two findings that cost real time to establish:

- **`--thread-count` defaults to `Environment.ProcessorCount`**, so it varies by
  machine. Never compare a user value against a hardcoded default to decide
  whether to emit it. This is why every option in `DownloadOptions` is `Optional`
  and `CommandBuilder` emits only non-nil values.
- **`-M` with `muxer=mkvmerge` and `format=MP4` slips past the engine's own
  guard.** `ParseMuxAfterDone` uppercases the format before parsing but compares
  the raw string against lowercase `"mp4"`, so the uppercase form is accepted and
  then fails later in the run. `MuxAfterDone.isValid` rejects it case-insensitively
  so the UI can refuse it up front. Covered by
  `CommandBuilderTests.mkvmergeCannotDoMP4`.

Bool options default to `true` for `--del-after-done`, `--auto-subtitle-fix`,
`--check-segments-count`, `--write-meta-json`, `--use-system-proxy` and
`--live-keep-segments`; all other bools default to `false`. Turning one of those
six off therefore requires the explicit `--flag False` form, which is why
`CommandBuilder` always emits an explicit `True`/`False` rather than a bare flag.

## argv, never a shell string

`CommandBuilder.arguments(for:)` produces the array handed to `Process`. No shell
is involved, so a URL containing `;` or `$()` cannot become command execution.
`shellCommand(...)` renders that same array for display only, using single-quote
escaping — double quotes would leave `$`, backticks and `\` live, so the command
shown to the user would not match the one that ran.

## `ToolLocator` probes absolute paths on purpose

A GUI app launched from Finder does not inherit the shell `PATH`, so a
`PATH`-only search finds Homebrew's ffmpeg when run from a terminal and silently
fails when the app is double-clicked. Well-known directories are probed first and
`PATH` is the last resort. See the type's own doc comment for the full reasoning.

## Reading the engine's output: four measured behaviours

All four were established by running the built binary, not by reading its source
or docs. Re-verify them when the submodule is bumped.

- **Log lines are not reliably newline-terminated.** `Logger.HandleLog`
  (`N_m3u8DL-RE.Common/Log/Logger.cs:94`) uses Spectre's `Markup` — the
  *non*-newline variant — for the first half whenever a log call has a `subWrite`
  part, so two records run together in the byte stream:
  `Content Matched: HTTP Live Streaming10:23:28.607 INFO : Parsing streams...`
  (verified with `xxd`: no `0x0a` between `Streaming` and `10:`). A parser that
  splits on newlines therefore yields merged records. Split on the timestamp
  pattern `HH:mm:ss.SSS LEVEL :` instead.
- **The engine spawns `tput` on exit and its errors land in our streams.**
  `Program.RestoreTerminal` (`N_m3u8DL-RE/Program.cs:66`) runs
  `Process.Start("tput", "cnorm")` to restore the cursor; the child inherits our
  pipes, so `tput: No value for $TERM and no -T specified` appears on **both**
  stdout and stderr. Setting `TERM=dumb` does *not* suppress it (measured — an
  earlier guess that it would was wrong). It cannot be disabled via any engine
  option, so `ProcessRunner` filters it out explicitly.
- 🔴 **The exit code is NOT a reliable success signal — this corrects an earlier note
  here that said it was.** That note read "Exit codes are clean and are the
  authoritative success signal: `0` on success, **`1` for a failed download**… Judge
  success by exit code, never by scraping log text." The second half is wrong and the
  advice was backwards. Measured: a download that loses segments logs
  `ERROR: Segment count check not pass, total: 8, downloaded: 6.`, then `ERROR: Failed`,
  and **exits 0**. `Program.DoWorkAsync` does set `Environment.ExitCode = 1`, but
  `CommandInvoker.InvokeArgs` ends with
  `Environment.Exit(await parseResult.InvokeAsync())`, and `System.CommandLine` returns 0
  for a handler that ran without throwing — so that assignment is discarded. The earlier
  note was most likely derived from a missing input file or a bad argument, which fail
  before or outside the handler and really do exit non-zero. Judge by
  `EngineOutputParser.verdict(in:)` first and the exit code second: see
  `DownloadJob.engineOutcome`. Captured in `Fixtures/engine-stdout-failed-verdict.txt`.
- 🔴 **A log level's separator depends on its length.** `Logger` pads the name to five
  characters before the colon, so `INFO : ` and `WARN : ` carry a space that `ERROR: `,
  `DEBUG: ` and `EXTRA: ` do not. A pattern requiring `LEVEL : ` therefore dropped
  **every ERROR and DEBUG record**: a failing download looked silent in the window, and
  `lastErrorMessage` could never find an `.error` record — which is why it had to fall
  back to WARN. (EXTRA never reaches a stream; `Logger.Extra` writes only to the log
  file.)
- 🔴 **The `tput` noise arrives glued to the last record**, because the engine's final
  line has no trailing newline. The measured tail is
  `ERROR: Failedtput: No value for $TERM and no -T specified`, so dropping any record
  that `isToolNoise` matches discarded the verdict itself. Cut the noise out of the
  message and drop only what is left empty.
- **`meta.json` / `meta_selected.json` are written with a UTF-8 BOM** (`efbbbf`).
  `JSONDecoder` chokes on it, so strip the BOM before decoding. Note the engine
  writes them into a timestamped subdirectory, e.g. `local_2026-09-11_10-22-31/`.

### The progress bar has six columns and no reliable separators

Order, from `SimpleDownloadManager.StartDownloadAsync`: description, 30-wide bar,
`MyPercentageColumn` (`value/max pct%`), `DownloadStatusColumn` (size),
`DownloadSpeedColumn`, `RemainingTimeColumn`. The spinner is dropped under
`--no-ansi-color`, which the app always passes.

🔴 **Between any two fields there may be one space or none**, because every column is
right- or centre-justified inside a width Spectre reallocates each repaint. Measured
in `Fixtures/engine-stdout-progress.txt`:

```
0/6 0.00% -0.00Bps --:--:--       size is "-", speed is 0.00Bps
1/6 16.67% -304.00KBps00:00:01    dash glued to the speed, speed glued to the ETA
2/6 33.33% 608.00KB/3.56MB304.00KBps00:00:02
6/6 100.00%2.34MB - 00:00:00      finished: one size, and the speed becomes "-"
```

Two placeholders to know: the size column is `-` until the first whole-second tick
(and shows one cumulative size once finished), and the speed column is `-` once
finished. A pattern that assumes single spaces reads the leading dash as part of the
rate and reports **`-585.94KBps`** — a negative speed, which is impossible; that was
shipped for a while.

⚠️ **Correction to an earlier note here:** that mis-binding did *not* stop the bar
advancing. Running the old pattern over the capture yields the full
0 → 16.67 → … → 100 sequence, because its greedy `[^\s(]*` backtracks until the
trailing ETA matches. What it broke was the detail — no transferred size at all, and
a garbled speed. Do not re-derive the wrong cause from the symptom.

### 🔴 A download can legitimately sit at 0% for its whole duration

Reproduced, not inferred: one segment, served with `Transfer-Encoding: chunked` and no
range support. `SimpleDownloadManager` first tries `LargeSingleFileSplitUtil` to split
a single segment into parallel ranges; when that fails it sets `SpeedContainer
.SingleSegment`, and `DownloadSpeedColumn` only swaps the task's counts for byte
counts when `ResponseLength` (the `Content-Length`) is known. With neither, `MaxValue`
stays **1** and `Value` stays **0** until the segment lands: measured 52 repaints of
`0/1 0.00%` across five seconds, then `1/1 100.00%`. Only the speed moves.

So `Progress.fraction` comes from the **percentage**, never from dividing the counts
(they are bytes in the other mode), and `Progress.isDeterminate` is false at 0% so the
UI can show an indeterminate bar instead of one frozen at zero — which is what made
this look like an app defect rather than a missing HTTP header.

To reproduce: serve a one-segment playlist from a handler that writes chunked and sends
no `Content-Length`, then run the engine against it.

### 🔴 One progress bar **per stream**, all reprinted together with no separator

`StartDownloadAsync` calls `ctx.AddTask` once per selected stream, and every repaint
re-renders the whole table — video, audio, subtitles — back to back with **no newline
between the rows**. Measured in `Fixtures/engine-stdout-multi-stream.txt`:

```
Vid 640x360 | 800 Kbps ━━━…━━  2/4 50.00% 768.00KB/3.00MB256.00KBps00:00:02
Aud English Audio | en ━━━…━━ 0/100 0.00%               -     -      --:--:--
Sub en | English       ━━━…━━ 0/100 0.00%               -     -      --:--:--
```

So one chunk of output yields three readings per repaint. A single-slot `progress`
field therefore displayed **the last row of the table**: a job fetching video first
showed the subtitle task's 0% while the video was half done. `DownloadJob` keeps one
reading per stream, keyed by `Progress.streamDescription`, and folds repaints in with
`record(_:)`.

Three consequences worth knowing:

- **A queued task reports `0/100`**, not `0/1` — 100 is Spectre's default `MaxValue`,
  assigned before `DownloadStreamAsync` learns the segment count. `Progress.hasStarted`
  exists so that never gets presented as "0 of 100 segments".
- **Only the transferring task has a rate**; the engine prints `-` for one it has not
  started *and* for one that has finished. That is how `DownloadJob.activeStream`
  identifies which track is being fetched.
- **Overall progress is the mean of the per-stream percentages.** Summing the counts
  would weight a pending one-segment subtitle track (`0/100`) as heavily as a
  four-segment video, and following the active stream instead would send the bar back
  to zero at every track boundary.

The descriptions come from `StreamSpec.ToShortShortString()`, whose `Vid`/`Aud`/`Sub`
prefixes are **hardcoded literals, not localised**, which is what makes them safe to
anchor a pattern on.

### Progress repaints bleed into log records

The bar is reprinted between log records, so its description and glyphs accumulate on
whichever record printed last. Measured before the fix: one record **2371 characters**
long, of which almost all was `Vid Kbps` and `━` repeated.

The token pattern therefore consumes the description and the bar run along with the
numbers, so a repaint is removed as one unit and nothing is left to bleed.

⚠️ **Corrects an earlier approach recorded here.** The first fix learned the
description from the gaps between repaints and stripped it from the *end* of each
message. That silently cut real text: the engine logs
`ResString.startDownloading + streamSpec.ToShortString()`, so
`Start downloading...Vid Kbps` genuinely ends with a stream name and came out
truncated to `Start downloading...`. Only the bar's own copy is residue.

The description pattern is **tempered** — `(?:Vid|Aud|Sub)(?:(?!Vid |Aud |Sub )…)` —
so it must begin at the last prefix before the bar. Without that, a log line that
names a stream (`Selected streams:` prints three) gets swallowed into the description
and disappears from the log.

### The IL3050 AOT warning is a false alarm

`scripts/build-engine.sh` surfaces an upstream AOT warning claiming
`JsonStringEnumConverter` "can break functionality when AOT compiling", and it
looks alarming because `--write-meta-json` defaults to **true** — i.e. it would
affect every download. Measured: it does not break. The engine also registers a
source-generated `JsonContext`, so the runtime uses generated code rather than
reflection. A local-manifest run produced valid JSON with enums correctly
serialised as strings (`"Method": "NONE"`) and exit code 0. Do not chase this
warning, and do not disable `--write-meta-json` because of it.

## The engine demands ffmpeg at startup, even with `--skip-download`

Running the engine without `--ffmpeg-binary-path` from inside the app failed with:

```
System.IO.FileNotFoundException: ffmpeg not found, please download at: …
```

thrown from `Program.DoWorkAsync` before any parsing. It is checked up front, not
lazily when muxing begins, so `--skip-download` does not avoid it. This is why
`DownloadCoordinator.startJob` filling in `--ffmpeg-binary-path` from
`ToolLocator` is **required**, not an optimisation: a GUI launch has no Homebrew
directory on `PATH`, so the engine's own lookup finds nothing.

## `ProcessRunner` strips `DYLD_*` from the child environment

Measured, not defensive. Launching the engine from a host that injects a dylib
killed it before `main`:

```
dyld[…]: terminating because inserted dylib
'@executable_path/__preview.dylib' could not be loaded
```

It exited with code **6** and printed only that message, while the identical argv
from a shell exited 0. Xcode Previews injects `__preview.dylib`, and
`DYLD_INSERT_LIBRARIES` is inherited by every child, but the engine is an
unrelated executable that can never load it. `childEnvironment()` therefore
removes `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH` and
`DYLD_ROOT_PATH`.

⚠️ **Do not test this guard with `/bin/sh`.** SIP-protected system binaries have
`DYLD_*` stripped by dyld itself, and a shell also *forwards* the already-stripped
environment to anything it execs — so a shell-based probe passes whether or not
this code does anything. See `M3U8DownloaderTests/AGENTS.md`.

## 🔴 `TERM=dumb` crashes the engine's progress bar — `ProcessRunner` strips `TERM`

Xcode sets `TERM=dumb` for a debugged app, and it is inherited by children. The
engine's Spectre.Console progress bar sizes itself from `TERM`; told the terminal
has no capabilities, it computes a width that makes its own renderer throw:

```
System.ArgumentException: Offset and length were out of bounds for the array…
   at Spectre.Console.LiveRenderable.<Render>d__25.MoveNext()
```

The download dies immediately after `fMP4 is detected, binary merging is
automatically enabled`, leaving only `meta.json`, `meta_selected.json` and
`raw.m3u8` — about 68 KB where a real download would be hundreds of megabytes.

Measured with identical argv, varying only `TERM`:

| `TERM` | result |
|---|---|
| `dumb` | exit **134**, 0 bytes |
| `xterm-256color` | exit 0, 17 MB |
| **absent** | exit 0, 17 MB |

So `childEnvironment()` removes `TERM` entirely, alongside the `DYLD_*` keys.
Absent is safe and is what a GUI-launched app would have anyway; being explicitly
told "dumb" is what breaks it. `--no-ansi-color True` does **not** help — that
controls colour, not the progress renderer's sizing.

⚠️ Do not probe `TERM` by expanding `${TERM-…}` inside `/bin/sh`: measured, the
shell reports `dumb` even when the variable is genuinely absent from `environ`,
because it substitutes its own default. Use a compiled `getenv` probe. (`sh` does
*forward* the real environment correctly — it only lies about its own expansion.)

## The `68 KB output` signature

A download that produces only `meta.json`, `meta_selected.json` and `raw.m3u8` has
crashed before fetching any segment. Two distinct causes have produced exactly this
symptom: the interactive stream-selection prompt, and `TERM=dumb` above. Checking
for `*.m4s`/`*.ts` files is **not** a reliable test of success — segments are
deleted after merging, so a completed download also shows zero of them. Compare
total directory size instead.


## `PATH` under a GUI launch, measured

Running inside the app, `ProcessInfo.processInfo.environment["PATH"]` is exactly:

```
/usr/bin:/bin:/usr/sbin:/sbin
```

No `/opt/homebrew/bin`, no `/usr/local/bin`. ffmpeg was found only through
`ToolLocator`'s explicit `knownLocation` probing. A `PATH`-only search would work
in a terminal and fail from Finder, with nothing in the logs to explain it.

## There is no preset system, and that is deliberate

The web generator's named presets existed because one Cloudflare deployment was
shared by several people — hence KV storage and an admin password. A single-user
Mac app has no such problem, so `OptionsPersistence` stores exactly **one**
implicit "what you had last time": no names, no list, no sharing. Do not
reintroduce named presets without a new reason.

Three fields are deliberately **not** restored, and each has a test asserting it:

- **`input`** (the stream URL) — single-use. Restoring it puts a stale link in
  front of the user as if it were the intended target, and it is the one field
  they must consciously supply.
- **`basic.saveName`** — per-download; reusing it collides with or overwrites the
  previous output.
- **`advanced.ffmpegBinaryPath`** — refilled from `ToolLocator` on every run, so
  storing it would pin a path that a Homebrew upgrade may have moved.

Metadata is stored as `Stored.metadataDefaults` — reusable fields only (title,
description, date), with `inputPath`, `outputPath` and `coverImagePath` cleared
because they refer to one finished file. `ContentView.restoreOptions` puts them back
into the Metadata tab's form; the paths stay empty, so a restored session cannot
start a metadata job until the user picks a file.
`OptionsPersistenceTests.storedMetadataWouldNotValidate` asserts that the stored
value never validates as-is, which is the property the whole arrangement rests on.

🔴 **Never let one panel's incomplete form disable another panel's button.** The
metadata pass used to be an optional sub-form of the download options, and its
"enabled but no paths yet" state fed `ContentView.validationIssues` — so restoring
that state left **both Add to queue and Download disabled**, with the only clue being
"An input file is required." sitting next to a perfectly good URL, and not even that
if the Metadata section was collapsed. Nothing errored or crashed; the app just
refused to start downloads. The first fix forced the pass off on restore. Promoting
Metadata to its own tab removed the mechanism outright: each tab validates only what
it edits, and its problems can only ever disable its own button, which sits directly
under the fields responsible. (An earlier version of this note also recorded that
metadata problems were prefixed `Metadata:` in the UI to disambiguate them — that
prefix is gone with the coupling that made it necessary.)

A version mismatch **discards** the stored value rather than migrating it: losing
remembered form fields is harmless, whereas a partially-decoded `DownloadOptions`
could silently produce wrong arguments. Bump `currentVersion` whenever a stored
field is renamed, removed or changes meaning — the `metadata` →
`metadataDefaults` rename happened to be safe only because the old key stopped
decoding, which was luck rather than design.


## The tool-path override keys are shared with `SettingsView`

`ToolLocator.Tool.overrideDefaultsKey` returns `enginePathOverride` and
`ffmpegPathOverride`, and `SettingsView` binds `@AppStorage` to those exact
strings. They must stay in sync — if they drift, Settings looks functional while
changing nothing, which is how the override sat unreachable for a while even
though `LocateError.recoverySuggestion` already told users to "set an explicit
path in Settings".

Verified end to end: no override resolves ffmpeg via `knownLocation`; writing
`ffmpegPathOverride` resolves via `userOverride`; and an override pointing at a
non-existent file **fails loudly** instead of falling back to another binary.

## Process output must be buffered, never dispatched per chunk

`DownloadCoordinator.run` collects output into an `OutputBuffer` and drains it on
the main actor, with a **final drain before any state decision**.

An earlier version did `Task { @MainActor in self.ingest(…) }` inside the output
callback. Those tasks are only *scheduled*, so a fast run reached a terminal state
before any of them executed. Measured with `--skip-download` (≈0.05 s): the job
reported `succeeded` with **0** log records, while the same argv through
`ProcessRunner` directly yielded 678 bytes and **11** parsed records. Nothing
errored — the log was simply empty.

The final drain has to precede the state decision because failure reporting reads
the log for the engine's own error text: with output lost, a failed download would
show a bare exit code instead of the reason.

## The engine appends a .NET stack trace to fatal errors

A real failure produced a single WARN record containing the cause followed by a
dozen frames:

```
nodename nor servname provided, or not known (example.invalid:443)Unhandled exception: …
   at N_m3u8DL_RE.DownloadManager.SimpleDownloadManager.<DownloadStreamAsync>d__8.MoveNext() + 0x4778
--- End of stack trace from previous location ---
   at Spectre.Console.Progress.<StartAsync>d__36.MoveNext() + 0x6c
```

`DownloadJob.humanReadablePrefix(of:)` cuts at the first `at ` frame or
`--- End of stack trace` marker, taking the message from ~25 lines to 1. The
**full text stays in the log** — the trimming only affects what the window shows.
It never returns empty, because a message consisting only of frames would
otherwise leave the UI with a blank error.

## 🔴 The engine shows an interactive prompt when no streams are selected

This is the single hardest constraint on driving the engine from a GUI.

`Program.DoWorkAsync` picks streams through four branches in order: `AutoSelect`,
`SubOnly`, any of the three **keep**-filters (`-sv`/`-sa`/`-ss`), and otherwise
`FilterUtil.SelectStreams`, which opens a Spectre.Console
`MultiSelectionPrompt`. That prompt needs a terminal. Driven as a child process
with a piped stdout it crashes part-way through rendering:

```
System.ArgumentException: Offset and length were out of bounds for the array…
   at Spectre.Console.LiveRenderable.<Render>d__25.MoveNext()
   at Spectre.Console.MultiSelectionPrompt`1.Show(IAnsiConsole)
   at N_m3u8DL_RE.Util.FilterUtil.SelectStreams(IEnumerable`1)
```

Reproduced on a real Apple HLS master playlist: 17 streams parsed fine, then the
crash.

**The app asks instead.** `DownloadCoordinator` runs the engine once with
`--skip-download` to get `meta.json`, presents the tracks in
`StreamSelectionView`, then runs the real download with `-sv`/`-sa`/`-ss` built
from the choice. An earlier version silently forced `--auto-select True` here; that
avoided the crash but downloaded tracks the user never saw, so it was replaced.

Two subtleties that make this easy to get wrong:

- **`--auto-select False` is not a selection.** It takes the same interactive
  branch as omitting the flag entirely.
- **Drop filters do not count.** The engine's branch tests only the keep-filters,
  so `-dv`/`-da`/`-ds` alone still reaches the prompt.

`hasExplicitStreamSelection` mirrors that branch order and must be re-checked
against the submodule whenever it is bumped.

## Turning a chosen subset back into `-sv`/`-sa`/`-ss`

`StreamCatalog` builds the filters. Four constraints shape how, each established
by reading `ParseStreamFilter` / `DoFilterKeep` / `ComplexParamParser` and then
confirmed against the running engine:

- **Matching is `IsMatch`, i.e. substring.** So every clause is anchored `^…$`.
  Without that, `name=English Audio` also matches `English Audio Descriptions` —
  a real pair in the Apple manifest.
- **Field values come from `meta.json`, never the log.** The log prints
  `Aud 2ch | English Audio | en | 2CH` while the `Channels` field is `2`. A filter
  built from the log's `2CH` matched nothing.
- **One filter per kind, fields ANDed.** Selecting tracks that differ in two or
  more fields creates a cross product: alternating both also matches combinations
  the user did not pick. `StreamCatalog.filter` therefore simulates the engine's
  matching locally and returns `.inexpressible` rather than downloading the wrong
  thing. `StreamSelectionView` surfaces that and disables Download.
- **`url=` is unusable, despite being the only unique field.** URLs contain `:`,
  which `ComplexParamParser` treats as the end of a value; escaping it as `\:`
  then triggers `result.Replace("\\", "")`, wiping the other regex escapes in the
  same pattern. URLs can also contain `key=value` query parameters that the parser
  mistakes for filter keys such as `res=`. Identification uses `res`/`codecs`/
  `range` plus a `bwMin`/`bwMax` window for video, and `id`/`name`/`lang`/
  `channel` for audio and subtitles — all colon-free in practice, with any
  colon-bearing value skipped.

`bwMin`/`bwMax` are in **kbps and multiplied by 1000** by the engine, compared with
`>=` and `<=`, so a one-kbps window pins an otherwise-identical video rendition.
(An early survey of the filter keys missed these two because the grep only matched
lowercase names; the full set is 18 keys.)

## Merging is on by default and the app never asks about it

`DownloadOptions.Merge.muxAfterDone` defaults to `MuxAfterDone()` — i.e. `-M
format=MP4` — which departs from the engine, where omitting `-M` leaves the tracks
as separate files. One playable file is what someone downloading a video almost
always wants.

Turning it off is respected silently: there is deliberately **no** post-download
prompt asking whether to combine. An earlier iteration had one, along with a
`MuxCommandBuilder` that ran ffmpeg over the leftover tracks; both were removed
when the default flipped, since a default-on setting the user can switch off makes
the question redundant.

MP4 is safe as the default even for streams with subtitles: measured, the engine
converts SRT to `mov_text` for MP4 and produces one file with video, audio and
subtitle tracks (`ffprobe` confirms `0,h264,video / 1,aac,audio / 2,mov_text,subtitle`),
leaving no loose files behind.

## The ffmpeg metadata pass is its own job, not a step of a download

`DownloadJob.options` is **`Optional`**, and `nil` is what makes a job a metadata
job: `startJob` branches on it and goes straight to ffmpeg without touching the
engine. `kind` is derived from the same field, so there is no second flag that could
disagree with it — an earlier sketch had a `kind` enum next to non-optional options,
which is exactly that hazard.

This replaced a post-download pass. `DownloadJob.metadata` used to be an optional
step that `runMetadataPassIfNeeded` ran after a successful download; a download job
now always finishes at `.succeeded`, and that function is gone. Two reasons:

- The pass has to work on files this app never downloaded, which the coupled version
  structurally could not do.
- It shared `ContentView.validationIssues` with the download form, which is how an
  incomplete metadata form silently disabled the Download button (see the preset
  section above).

Accepted cost: chaining a download into a metadata pass is now two jobs, with the
user pointing the Metadata tab at the file the download produced. `Kind`-aware tests
live in `MetadataAndJobTests` (`DownloadJobTests`, `MetadataJobCoordinationTests`).


## A fatal exception is not reliably logged at WARN or ERROR

Because the engine omits newlines, its `Unhandled exception:` text is appended to
whichever record was mid-print. In the crash above it landed on an **INFO** line
listing a subtitle track:

```
INFO : Sub subtitles | en | EnglishUnhandled exception: System.ArgumentException…
```

`lastErrorMessage` originally searched only WARN/ERROR records, so it returned the
last ordinary warning and the window reported **"Writing meta json"** for a crash.
It now matches `Unhandled exception:` at any level first, and strips the unrelated
log text the exception was glued onto. Level-based lookup remains the fallback for
non-fatal problems.

Two later findings belong with this one:

- Part of why the level-based lookup was so weak is that **ERROR records were being
  dropped entirely** by the log-prefix pattern (see the separator note above). The
  fallback was effectively WARN-only, whatever it said.
- Now that ERROR records do parse, the lookup **skips the closing `Failed` verdict**.
  It is always the last ERROR record and says only *that* the run failed, so taking the
  last one blindly reported "Failed" and buried the line above it that says why
  (`Segment count check not pass, total: 8, downloaded: 6.`).






## 🔴 The engine localises its messages by system language, so `--ui-language en-US` is pinned

Measured on this machine, whose preferred languages are `("en-CN", "zh-Hans-CN")`: without
`--ui-language` the engine printed its log in Chinese, so every English-keyed match
(`Save Name: `, the verdict lines) silently stopped matching — no error, the feature just
never fired. `DownloadCoordinator.prepared(_:ffmpegPath:)` therefore sets `en-US` when the
user has not chosen one, and `EngineOutputParser.saveName(in:)` recognises only the English
form on purpose rather than guessing translations. An explicit choice in Advanced is
respected, and then those matches are expected not to fire. Guarded by
`PreparedOptionsTests` and `SaveNameParsingTests.ignoresChinesePrefix`.

`Save Name: ` is glued to the next record's timestamp like everything else in the capture
(`Save Name: probe210:24:55.721 INFO : …`), so the name is read from the *record*, never the
raw line — `foundInCaptures` pins `probe2`, not `probe210`.

## Where a job's output goes, and how Show in Finder finds it

`OutputLocator` is the one place that answers both "where does this write" (the engine's
working directory) and "where do we look afterwards" (Show in Finder). Keep them one
function: two derivations would drift and the button would open the wrong folder.

Files are matched by **name prefix and modification time together** — prefix alone picks up
last week's download of the same title, time alone picks up whatever a browser wrote to
Downloads meanwhile. A prefix, not an exact name, because one download yields several files
(`name.mp4`, `name.en.srt`). Directories are skipped (the temp folder shares the save name).
When nothing matches, the UI opens the directory instead: the right folder beats the wrong
file. The save name comes from the engine's `Save Name:` line when present
(`DownloadJob.resolvedSaveName`), because the name is otherwise derived from the URL.

`MediaStream.presentation` (`MediaStreamPresentation.swift`) is the selection sheet's
structured form of a track. `MediaStream.summary` is untouched on purpose: it is quoted in
the "cannot be requested precisely" message and asserted on elsewhere.

## 🔴 The pipe is read in arbitrary pieces; `ChunkAssembler` stops a split record losing the verdict

Parsing each drained piece on its own turned `ERROR: Fai` + `led` into a record reading
`Fai`. The engine exits 0 on a failed download, so the `ERROR: Failed` verdict is the only
thing separating a failure from a "succeeded" row — and a split silently dropped it.
(Found by review, reproduced on the parser directly; not yet seen in a real run, so the
frequency is unmeasured.)

`ChunkAssembler` keeps the unfinished last record between pieces
(`EngineOutputParser.splitUnfinishedTail`). Rules that are easy to get wrong:

- A record is closed only by the **next log prefix**, with progress tokens inside it removed
  and the rest joined — that is how `Unhandled exception:` text ends up on the record it
  followed. So the tail starts at the last prefix, **not** at the last progress token.
  Cutting at the last token (the first attempt) parsed that exception text on its own,
  where it has no prefix and is dropped.
- Complete progress tokens (ones carrying an ETA) are released immediately even while a
  record is pending; otherwise the bar freezes for as long as the engine stays quiet.
- An **idle drain tick releases the tail**; `finish` releases it unconditionally. The
  engine writes a record in one go, so a gap longer than a drain interval (120ms) between
  two halves is outside what this can fix.
- Probe and metadata runs drain once at the end, so they never see a split.

Guards: `ChunkAssemblerTests` cuts every capture at every (or sampled) offset and requires
the same records and progress as a whole parse; `CoordinatorSplitRecordTests` drives a
stand-in engine through the coordinator, because a missing hookup passes every unit test.
Both were mutation-checked, including removing each of the two coordinator call sites.

## The probe run is bent so it can only write `meta.json` where we look

`DownloadCoordinator.probeOptions(from:directory:)` forces `--tmp-dir` and `--save-dir` to
the probe directory and `--write-meta-json True`. Measured against the engine: with the
user's `--tmp-dir` the files land in `<tmp-dir>/<save-name>/` and the probe directory stays
empty; with `--write-meta-json False` no `meta*.json` is written at all. Either made the
probe report "the engine did not write a stream list", which reads as a manifest problem.

## Values are trimmed in `CommandBuilder`, not only in the UI

`validate` judged the input by its trimmed form while argv carried the original, so a URL
pasted with the keyboard (the Paste button trims; Cmd-V does not) passed validation and the
engine rejected it. The input and every `append(option:)` value are now trimmed, and a
whitespace-only value counts as unset.

## Stopping: SIGTERM, then SIGKILL, over the whole tree — and the slot stays busy until it is gone

`ProcessRunner.stop` signals `ProcessTree.members(rootedAt:)` (the process and every
descendant, recorded **before** signalling because children are re-parented to launchd once
the root exits), then SIGKILLs whatever is still alive after `terminationGrace` (5s, a
judgement call, not measured). Members are matched by pid **and start time**, so a delayed
SIGKILL cannot hit a reused pid.

⚠️ **A correction against the review that prompted this.** It claimed `Process.terminate()`
leaves grandchildren running and holding our pipes. Measured here, that is false for the
ordinary case: Foundation makes the child a process-group leader (pgid == pid) and
`terminate()` already took down a `sleep` grandchild in that group. What it does not do is
send SIGKILL, and a process that ignores SIGTERM then ran forever — that is the real bug
(`stubbornProcessIsKilled`). The tree walk additionally covers a grandchild that left the
group. Replacing the tree-wide SIGTERM with a plain `terminate()` survives every test, for
that reason; it is an equivalent mutant, not a gap.

Consequences wired through `DownloadCoordinator`:

- `cancelJob` sets `isStopping` and **keeps the task registered**. Dropping it at once (the
  old behaviour) let the next job start beside a process still shutting down.
- `maximumConcurrentDownloads` (1) is now enforced; it was declared and never read. A start
  while busy sets `isWaitingForSlot` and starts by itself when a slot frees
  (`startNextWaiting`, called wherever a task deregisters).
- 🔴 **Every exit path of a task must deregister it.** The probe task had two early
  `return`s that skipped `runningTasks[id] = nil`; harmless before, but with a one-slot limit
  a leaked registration blocks every later job forever. It now uses `defer`
  (`failedProbeFreesTheSlot`).
- `stopAllAndWait` is what Quit uses: cancel everything, wait for the tasks (so the
  processes), bounded by a timeout.
- Removing a waiting job is guarded three times over (`removeJob`, `cancelJob`, and
  `startJob` ignoring an unknown id), so removing any one of them is invisible to the tests.
  Left in on purpose.

Not covered by a test: `AppDelegate.applicationShouldTerminate` (the alert and the
`.terminateLater` reply) and the slot gate in `confirmStreamSelection`.

## 🔴 Mutation testing under this setup: never kill the runner, and trust only named failures

Two things that produced false results here, both caused by the harness rather than the code:

- Killing a mutation script (or its `xcodebuild`) mid-run **leaves the mutation in the
  source**. A deterministic test failure appeared that was really `task.cancel();
  runningTasks[id] = nil` left behind in `cancelJob`. Check with `git diff`/`grep` for the
  mutated text after any interrupted run, and run mutations in the foreground to completion.
- 🔴 **Run the harness from a heredoc, not from a script file in `/tmp`.** A mutation loop
  saved as `/tmp/x.sh` or `/tmp/x.py` failed every build with `sandbox-exec: sandbox_apply:
  Operation not permitted` (the Swift macro plugin cannot nest a sandbox) or hung the test
  host, while the same loop pasted as `python3 - <<'EOF' … EOF` (or the commands inline)
  worked every time. Measured by alternating the two; the cause is not understood. Adding
  `-disable-sandbox` to `OTHER_SWIFT_FLAGS` did not help — the host hung instead.
- `xcodebuild test` sometimes fails to start (`The test runner hung before establishing
  connection`, or a Swift macro plugin `sandbox_apply: Operation not permitted`). Both read as
  "tests failed", so a mutation run that counted any `TEST FAILED` as killed reported
  mutations as caught that no test had actually seen. Count a mutation as killed only when a
  specific `Test case '…' failed` line names a test, and confirm the unmutated baseline
  passes with at least one test running.

## Credentials are not persisted

`OptionsPersistence.sanitized` drops headers whose name looks like a credential (substring
match on cookie/auth/token/key/secret/session/password/credential), `merge.keys`, the custom
HLS key/IV and a proxy URL with userinfo. The earlier design said headers are "reused with the
next download"; that was too broad — a `Cookie` was sent to whatever host came next, from a
plist that held it in plain text. `Referer`/`User-Agent`/`Origin` are still remembered.

`load()` scrubs old data **and rewrites it**, because nothing re-saves at launch (the restored
draft equals what is stored) and the secret would otherwise sit on disk until the next edit.
The engine also writes its full command line, headers included, to its own log file — see
the next section.

## The engine's log goes to `~/Library/Logs/M3U8Downloader/engine.log`

Left alone the engine writes `Logs/` next to its own executable, which is inside the signed
app bundle (measured: 16 files accumulated in `build/engine/osx-arm64/Logs`). `prepared()`
sets `--log-file-path` unless the user chose `--no-log` or a path. Verified against the
engine: it creates the directory, writes the file there and leaves its own directory alone.
An explicit path is **overwritten per run**, so a probe's log is replaced by the download's.

## A failed metadata pass cleans up after itself, and says why

ffmpeg creates its output before it has anything to put in it. Without `-y` a failed or
stopped run left a zero-byte file and every retry then failed with "already exists" until the
user deleted it by hand (measured). `startMetadataJob` records whether the output existed
beforehand and, if it did not, deletes it on failure or stop; a file that was already there
is never touched. The reason shown comes from `FFmpegOutput.level(for:)`, which marks ffmpeg's
error lines `.error` (they were all `.info`, so `lastErrorMessage` found nothing and the row
said "exited with code 1"); ffmpeg's closing `Conversion failed!` is skipped as the reason,
like the engine's own `Failed`. Indented lines are never errors: the input's own metadata is
printed indented and a title can say anything.

## The save folder is created before launch

`Process` reports a missing working directory as "The file “X” doesn’t exist", which was
then wrapped as "Could not start N_m3u8DL-RE" — blaming the engine for an unmounted drive or
a mistyped folder. `launchDownload` creates the folder, or fails the job with a message that
names it. `~` is expanded for `--save-dir`/`--tmp-dir` (`OutputLocator.expandingTilde`);
`URL(fileURLWithPath:)` already does it for our own side. That the engine does not is
assumed, not measured here.

## 🔴 The overall bar is weighted by estimated bytes, not averaged

`overallPercent` used to be the plain mean of the per-stream bars (chosen because it is
monotonic). With one video and fifteen other tracks, a video at 800/900 read about 5% overall:
the bar was telling the user how many tracks had started, not how much was left.

Streams are now weighted by `duration × bitrate` (`StreamEstimate.weight`), read from the lines
the engine logs after `Selected streams:`:

```
Vid 640x360 | 800 Kbps | avc1.4d401e | 4 Segments | ~00m16s
Aud aud | English Audio | en | 3 Segments | ~00m12s
Sub sub | en | English | 1 Segment | ~00m04s
```

Things that are easy to get wrong:

- **Only the lines after the marker count.** The same lines are logged for every *extracted*
  stream first; reading those too doubled the list (`onlyAfterTheMarker`). The list ends at the
  first record that is not a stream line.
- The **progress-bar labels differ** from these lines (`Vid 640x360 | 800 Kbps` against the long
  form above), so bars are matched to announced streams by kind and by position *within that
  kind*, never by label.
- Weights are **fixed once the list is read** and never revised from the sizes the engine reports
  later: those are extrapolations that move, and revising would make the bar jump.
- A stream announced but not yet drawn counts as 0% in the denominator, so a late row cannot pull
  the bar back. Replaying the real multi-stream capture is asserted to be monotonic.
- Missing bitrates are assumed (audio 128, subtitle 1, video the highest announced video bitrate or
  2000 Kbps). The assumptions only need to get *which stream dominates* right; they are round
  numbers, not measurements. If the marker is not seen (the user overrides `--ui-language`) the
  weights fall back to the stream's kind, which still beats a plain average.
- Bytes the engine has actually downloaded are not used. Not tried: it would need totals for
  pending streams, which the engine does not have either.

## 🔴 The freeze: a long label, a growing carry, and a quadratic pattern

A long download (a 1h17m HDR video with 15 tracks) froze the window near the end. Found with
`sample` on the hung app: the whole main thread was inside one
`ChunkAssembler.feed → splitUnfinishedTail → progressToken` regex call. Three things combined:

1. **The label limit was 60 characters.** The engine's labels for that stream are 62 and 63
   (`Vid 640x360 | 657 Kbps | 29.97 | hvc1.2.20000000.H120.B0 | PQ`,
   `Aud audio-stereo-aac-128 | English Audio Descriptions | en | 2CH`), so those rows did not match
   as one piece. The stream got a truncated label (which also mis-keyed its per-stream state)
   and the text before the cut was left behind on every repaint.
2. **That residue accumulated in the carry** — about 350 bytes per tick (reproduced with rows
   copied from the real log: 3.6 KB after ten ticks, still climbing). Each 120 ms tick re-scans
   the whole carry.
3. **The progress pattern is quadratic on a long run of whitespace or bar glyphs**: it is tried
   at every position and from each consumes the whole run before failing. Measured: 2 000 spaces
   0.18 s, so a 64 KB carry meant minutes. (A lookbehind guard would fix it in the pattern, but
   Swift's regex engine does not support lookbehind.)

Fixes, each guarded by `LongLabelFreezeTests` and mutation-checked: the limit is now 200;
`EngineOutputParser.compactingRuns` caps runs of whitespace (16), bar glyphs (64) and digits (24)
before any matching; the carry cap is 16 KB instead of 64 KB.

⚠️ **Why the earlier tests missed it:** every capture is short and its labels fit in 60
characters. Real streams do not. The new tests use labels copied from the engine's own log of
the run that froze, and replay hundreds of repaints rather than one.

⚠️ This is also why the weighted overall bar and the per-stream weights could be wrong for such
streams before: they key on the label, and a truncated one no longer began with `Vid`/`Aud`/`Sub`.

## `Segment count check not pass` is usually the server, not the network

`DownloadJob.Failure.explained` appends advice to that error. Measured on an Apple event
stream: one CDN segment answered `Content-Length: 2479526` and closed after **one byte** for
plain, HTTP/1.1, Range and cache-busted requests, so the engine's retries (default 3, 1 s apart)
never help; raising Threads/Retries is not the fix. Only some variants were damaged (5 of 34
at segment 325), so another stream works, or `--check-segments-count false` yields a file missing
that segment. The raw engine text stays first (`lastErrorMessage` is unchanged); matching relies on
the pinned `--ui-language en-US`.
