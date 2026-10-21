# SwiftUI layer

The window (`ContentView`), the two editing panels, the queue rows and the log drawer.
Shared visual pieces live in `Views/PanelChrome.swift`; see `Core/AGENTS.md` for the
option model and everything that drives a process.

Deployment target is **macOS 14.0** even though the toolchain is much newer, so
anything from 15+ (`.tabViewStyle(.sidebarAdaptable)`, `glassEffect`, `Tab`) will
compile against the SDK and then fail to run on the stated minimum. Check before
reaching for a new modifier.

## The layout encodes what the app is for

Three regions, in priority order:

- **Main area** — the option form for the active tab, at full width. Composing a job is
  the app's purpose, so it gets the space.
- **Trailing `.inspector`** — the queue, with progress. Shown by default, toggled from
  the toolbar, and force-shown by `enqueue` so a newly added job is never added into a
  hidden list.
- **Bottom drawer** (`JobDetailView`) — the log, **collapsed by default**. It only
  matters when something goes wrong.

An earlier arrangement inverted all three: a `NavigationSplitView` with the option form
crammed into a ~430pt sidebar and the job list occupying the main area. Do not put the
form back in a sidebar; it is the primary surface, not a configuration drawer.

`JobRowView` is laid out for the ~330pt inspector column: captions stack and truncate
to one line rather than spreading across the row. It previously put segments, speed,
ETA and the phase on one line with a `Spacer`, which needs a full-width pane.

The two caption lines split the job's scope from the track's, because the engine reports
size, rate and ETA **per stream** — see the 🔴 note in `Core/AGENTS.md` about one bar
per stream:

```
▓▓░░░░░░░░░░                                     ← job overall: the mean of the streams
16.7% · 768.00KB/3.00MB · 256.00KBps · ETA …      ← overall %, active track's numbers
Downloading · 1/3 · Vid 640x360 | 800 Kbps · 2/4 segments
```

Naming the active track is the whole point of the second line: with one bar and one
caption there was no way to tell which track the numbers belonged to, and the row could
show a pending subtitle track's 0% while the video downloaded. Each line is ordered so
that truncation loses the least useful part first.

The bar is **indeterminate whenever the overall percentage is 0**, and that is not an
edge case: see the 🔴 note in `Core/AGENTS.md` about single-segment downloads with no
`Content-Length`, where 0% is all the engine ever knows.

## The URL is the primary control, not a row in a form

`StreamURLField` sits above the option form in `OptionsPanelView`, auto-focused, with
Paste / Choose… / Clear. Everything below it is optional tuning, so it must not be
scrolled away or buried in a section. The former `Basic` section is `Output` (save name,
save to, temporary files); its save-name prompt says "Taken from the link" because an
empty name is a real, working state. The placeholder must stay short: a longer one was
truncated mid-word ("choose a l") at the default window width.

Finished jobs offer **Show in Finder** and failed ones **Show Log** (`JobRowView`
callbacks, wired in `ContentView.reveal` / `showLog`); see `OutputLocator` in
`Core/AGENTS.md` for how the files are found.

`LabeledContent` is used in `SettingsView` and `ExtraArgumentsField` so that only the
*value* is monospaced; applying `.monospaced()` to the whole row made the labels look like
code too.

## 🔴 `ExtraArgumentsField` must not round-trip through a plain join

The field is `@State` text over an `[String]` model. `onAppear` used to write
`arguments.joined(" ")` back into the text, which fires `onChange`, which re-tokenised it:
`["-H", "A B"]` became `["-H", "A", "B"]` on every re-appearance (a collapsed section, the
other tab, a restart) and the command that ran changed with no sign. `render` quotes what
`tokenize` would split, `onAppear` only seeds an empty field, and `onChange` skips writing
an unchanged value. Covered at the `render`/`tokenize` level by
`ExtraArgumentsRoundTripTests`; the `onAppear`/`onChange` wiring itself has no test, since
it is SwiftUI state.

## Return belongs to the URL field, not to the window

`Download` used `.keyboardShortcut(.defaultAction)`, which reaches the default button from
a focused text field — so Return in "Save name", the proxy field or a header value could start
a download (read from the code, not reproduced, since there is no way to drive the macOS UI
here). Return now only submits from `StreamURLField` (`onSubmit` → `submitFromURLField`,
which checks the same conditions as the button) and the button is ⌘Return.

The main window is a `Window`, not a `WindowGroup`: the old comment said "single window" but
File > New Window was still offered. Removing a *running* job asks first
(`requestRemoval`), because the trash can sits next to Stop. Neither is covered by a test.

## Quitting stops the work first

`AppDelegate.applicationShouldTerminate` (in `M3U8DownloaderApp.swift`, via
`@NSApplicationDelegateAdaptor`; SwiftUI has no equivalent) asks before quitting with work
running, then replies `.terminateLater` until `DownloadCoordinator.stopAllAndWait()` returns.
Replying at once would exit while the engine and its ffmpeg were still shutting down — and
before this existed, nothing stopped them at all. The delegate is created before the scene,
so the coordinator is handed over from `ContentView`'s `onAppear`. Untested: it needs a live
`NSApplication`.

A running row shows "Stopping…" and a disabled Stop button while `isStopping`; a job started
while another runs shows "Waiting for the current job to finish".

## Separating the inspector from the main area

Two changes, neither decorative:

- The queue's `List` gets `.scrollContentBackground(.hidden)` over a
  `.regularMaterial` fill. A `List` paints an opaque `textBackgroundColor`, so the two
  columns rendered as one continuous white sheet with no visible boundary at all.
- ⚠️ **`Divider()` outside a stack still draws horizontally.** An
  `.overlay(alignment: .leading) { Divider() }` meant as the column's left border
  produced a rule straight across the middle of the inspector, which reads exactly like
  a rendering bug. Use `Rectangle().fill(.separator).frame(width: 1)`.

Also: a `List` holding a couple of short rows sizes to its content, which left the
footer's `Divider` stranded mid-column. The list needs an explicit
`.frame(maxHeight: .infinity)`.

## Two tools, one queue

`Download` and `Metadata` are top-level tabs (`ContentView.Workspace`) that swap the
main panel only. The queue, the log drawer and the tool banners are shared, because
both kinds of work are watched in the same place — a second list would mean two places
to check whether something finished.

Each tab validates only what it edits and its problems appear next to its own
buttons. This is load-bearing, not cosmetic: see the 🔴 note in `Core/AGENTS.md`
about an incomplete metadata form disabling the Download button.

## 🔴 The window's chrome container must be its top-level view

Anything stacked above a `NavigationSplitView` — or above the `.inspector` used now —
leaves that container **still reserving a toolbar inset**. Measured: with a 46pt tab bar
above a split view, the first row of the job list rendered blurred and half-hidden under
a phantom 40pt band, looking like a rendering glitch rather than a job. The row was
there and selectable; it just could not be read. `.toolbar(.hidden, for: .windowToolbar)`
did **not** reclaim the space.

So window-wide chrome goes in the window toolbar, not in a bar of our own.

⚠️ `ToolbarItem(placement: .principal)` does **not** centre the item in this window,
despite what "principal" suggests. Measured item order is `[principal, flexibleSpace,
primaryAction]`, i.e. the tab picker sits at the **leading** edge after the traffic
lights and the inspector toggle at the trailing edge. That reads fine; just do not
expect centring, and do not add spacer items chasing it.

## `.labelsHidden()` empties a `Picker` whose options are `Label`s

It hides the picker's own title *and* the titles of `Label` options, so a segmented
picker built from `Label(title, systemImage:)` renders as blank segments — measured,
and it looks like a layout bug rather than a style choice. `.labelStyle(.titleAndIcon)`
on each option does not override it. Plain `Text` options are unaffected, which is why
`ContentView.workspacePicker` uses `Text` and therefore has no icons: without
`labelsHidden()` the picker's own "Tool" label appears beside the segments instead.

## What a preview snapshot cannot show

Xcode Previews renders each preview inside its own harness window and **hoists
`.toolbar` items into that harness's chrome**, where they appear greyed out. So
`ContentView`'s tab picker and inspector toggle are invisible in preview snapshots and
must be checked in the running app.

The cheap way to check them without a screenshot — Device Interaction does not support
macOS, see below — is to dump the real window's toolbar from a temporary `.onAppear`:

```swift
let window = NSApplication.shared.windows.first { $0.toolbar != nil }
for item in window?.toolbar?.items ?? [] {
    print(item.itemIdentifier.rawValue, item.view?.frame.size ?? .zero)
}
```

Measured with the current layout: **3** items — the tab picker at **165 × 36**, a
flexible space, and the inspector toggle at **36 × 36**. A dropped or collapsed item
shows as `(0.0, 0.0)`, which is what distinguishes "placed but empty" from "actually
laid out". (The earlier `NavigationSplitView` layout reported 4, including SwiftUI's own
`navigationSplitView.toggleSidebar`.)

Device Interaction (screenshots, taps) does **not** support macOS — it accepts only
iOS/watchOS/tvOS simulators. Do not capture the whole screen as a substitute: it
exposes whatever else the user has open, and the app window may not even be on the
captured Space.

Preview coverage worth using: `ContentView` has "Empty" and "With jobs" — use the
latter when touching the queue, since the empty state hides every layout problem the
rows have. `JobDetailView` has "Collapsed", "Expanded" and "Nothing selected".
`JobRowView`'s previews are framed at **330pt** on purpose, matching the inspector
column; widening them to check a layout defeats the point.

## 🔴 Only one `AGENTS.md` may live under a target's synchronized folder

The project uses Xcode 16+ `PBXFileSystemSynchronizedRootGroup`, so **every** non-source
file under a target's folder is picked up as a resource and copied *flat* into the
bundle. Adding this file next to `Core/AGENTS.md` therefore broke the build outright:

```
Multiple commands produce '…/M3U8Downloader.app/Contents/Resources/AGENTS.md'
```

Both targets now set `EXCLUDED_SOURCE_FILE_NAMES = *.md`, which keeps documentation
out of the bundles entirely — before that, the app was shipping `Core/AGENTS.md`
inside `Contents/Resources`. Verified after the change: no `.md` in either bundle, and
the test fixtures still arrive at their documented byte counts (`6080` for
`engine-stdout-failed-download.txt`).

## The app icon is an Icon Composer file, drawn as SVG

`AppIcon.icon` (a folder: `icon.json` plus `Assets/*.svg`) replaces the old `AppIcon.appiconset`,
which was an empty template — adding an `.icon` named `AppIcon` supersedes an asset-catalog icon
of the same name, and the target's `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` needed no
change. It sits inside the synchronized folder and is picked up without a project edit; the build
produces `AppIcon.icns` and an `Assets.car` holding the vector layers (checked with
`assetutil --info`).

Five layers, back to front: `1-tray` (60% opacity), `2-segment-1…3` (50% / 75% / 100%, so the HLS
segments fade in towards the head) and `3-head`, all opaque white on an automatic blue gradient;
translucency, glass and the dark/tinted looks come from Icon Composer, not from the SVGs. Edit the
SVGs (1024×1024, filled shapes only, no text) and keep colours and opacity out of them.

To look at it without opening Icon Composer — also how it was checked, in Default, Dark and Tinted:

```
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  M3U8Downloader/AppIcon.icon --export-image --output-file /tmp/icon.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

(`--rendition Dark`, or `TintedLight` with `--tint-color 0.6 --tint-strength 0.7`.) The
`icon.json` keys were written from memory of the format rather than from documentation; `ictool`
accepting and rendering it, including the per-layer `opacity`, is the evidence they are right.

## The tool banner must stay one row

A banner above the editing panel with a multi-line `Text` (`fixedSize(vertical:)`, long recovery
text) made the whole window lay out ~1 400 pt too tall: the pane slid under the toolbar and the
URL field, action bar and log were off-screen. Nothing shows in development because the engine is
embedded and no banner appears; it showed in an archive built without the engine, and would for
anyone without ffmpeg. Long text belongs behind "How to fix" (an alert), not in the banner.
`ToolBannerTests` fails on the old design (checked by restoring it); it measures the banner alone,
so a *new* cause of window overflow still needs a look at a Release build with the engine removed.
