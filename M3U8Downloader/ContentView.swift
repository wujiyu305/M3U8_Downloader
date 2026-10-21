import AppKit
import SwiftUI

/// The app's main window.
///
/// Two tools share it: **Download** drives the engine, **Metadata** runs a standalone
/// ffmpeg pass over a file that already exists. They are top-level tabs rather than
/// sections of one form, matching the web generator's own split.
///
/// The layout follows what the app is *for*. Composing a job — the URL, the options,
/// the metadata fields — is the main content area, at full width. Progress is a
/// trailing inspector, because it is something you glance at rather than work in. The
/// log is a bottom drawer, **collapsed by default**, because it only matters when
/// something goes wrong.
///
/// An earlier arrangement had the option form crammed into a sidebar with the job list
/// occupying the main area, which inverted all three of those priorities.
///
/// Both kinds of work land in the same queue: a second list would mean two places to
/// check whether something finished.
struct ContentView: View {
    /// Injected from the app so the Settings scene can share it.
    var coordinator: DownloadCoordinator

    /// Which tool the main area is showing.
    enum Workspace: String, CaseIterable, Identifiable {
        case download = "Download"
        case metadata = "Metadata"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .download: return "arrow.down.circle"
            case .metadata: return "tag"
            }
        }
    }

    @State private var workspace: Workspace = .download

    /// The options being edited for the next job. Kept separate from any queued
    /// job so editing the form never mutates something already running.
    @State private var draftOptions = DownloadOptions()
    @State private var draftMetadata = MetadataOptions()
    @State private var selectedJobID: UUID?

    /// Progress is on by default; the log is not. Neither is persisted — the log
    /// starts collapsed on every launch, which is the point of it being a drawer.
    @State private var showsQueue = true
    @State private var isLogExpanded = false

    /// The job whose pending decision is being shown, and the working state for it.
    @State private var decisionJobID: UUID?
    /// A running job the user asked to remove, awaiting confirmation.
    @State private var removalCandidateID: UUID?
    /// The fix-it text behind a tool banner's "How to fix" button.
    @State private var bannerDetail: BannerDetail?

    struct BannerDetail: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
    @State private var streamSelection: Set<String> = []

    /// Restores what the user had last time. Not a preset system: one implicit
    /// state, no names, and neither the URL nor the metadata paths are restored —
    /// see `OptionsPersistence`.
    private let persistence = OptionsPersistence()

    var body: some View {
        VStack(spacing: 0) {
            toolStatusBanner
            editingPanel
            Divider()
            actionBar
            Divider()
            JobDetailView(job: selectedJob, isExpanded: $isLogExpanded)
        }
        .inspector(isPresented: $showsQueue) {
            queue
                .inspectorColumnWidth(min: 280, ideal: 330, max: 480)
        }
        .frame(minWidth: 960, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .principal) {
                workspacePicker
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsQueue.toggle()
                } label: {
                    Label("Queue", systemImage: "sidebar.right")
                }
                .help(showsQueue ? "Hide the queue" : "Show the queue")
            }
        }
        .onAppear(perform: restoreOptions)
        // Saved on every edit rather than at quit: an app that is force-quit or
        // crashes would otherwise lose the settings, which is exactly when losing
        // them is most annoying.
        .onChange(of: draftOptions) { _, _ in saveOptions() }
        .onChange(of: draftMetadata) { _, _ in saveOptions() }
        // A job blocked on a decision opens its sheet automatically, so the flow
        // feels like the CLI's prompt rather than something to go hunting for.
        .onChange(of: firstPendingDecisionID) { _, newValue in
            if decisionJobID == nil, let newValue { present(decisionFor: newValue) }
        }
        // `isPresented` rather than `sheet(item:)`: the job is looked up from the
        // coordinator each render, so the sheet always reflects live state instead
        // of a snapshot taken when it opened.
        .sheet(
            isPresented: Binding(
                get: { decisionJob != nil },
                set: { shown in if !shown { decisionJobID = nil } }
            )
        ) {
            if let job = decisionJob {
                decisionSheet(for: job)
            }
        }
        .alert(
            bannerDetail?.title ?? "",
            isPresented: Binding(
                get: { bannerDetail != nil },
                set: { shown in if !shown { bannerDetail = nil } }
            ),
            presenting: bannerDetail
        ) { _ in
            Button("OK") { bannerDetail = nil }
        } message: { detail in
            Text(detail.text)
        }
        .confirmationDialog(
            "Stop and remove this job?",
            isPresented: Binding(
                get: { removalCandidateID != nil },
                set: { shown in if !shown { removalCandidateID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop and Remove", role: .destructive) {
                if let id = removalCandidateID { coordinator.removeJob(id: id) }
                removalCandidateID = nil
            }
            Button("Keep Running", role: .cancel) { removalCandidateID = nil }
        } message: {
            Text("It is still running. Removing it stops it and discards its log.")
        }
    }

    // MARK: - Workspace switching

    /// The window's top-level tab control.
    ///
    /// It lives in the **window toolbar**. Two measured findings put it there rather
    /// than in a bar of our own inside the window:
    ///
    /// - A container that owns the window's chrome — a `NavigationSplitView`, and the
    ///   `.inspector` used here — still reserves a toolbar inset when it is not itself
    ///   at the top of the window. With a bar above it, the first row of the job list
    ///   rendered blurred and half-hidden under a phantom band, and
    ///   `.toolbar(.hidden, for: .windowToolbar)` did not reclaim the space.
    /// - `.labelsHidden()` on a `Picker` also hides the titles of `Label` options,
    ///   which rendered the whole segmented control as two blank segments. Plain
    ///   `Text` options are unaffected by it, so that is what this uses — which
    ///   costs the icons, since a bare `Label` would then show the picker's own
    ///   "Tool" title next to the segments.
    private var workspacePicker: some View {
        Picker("Tool", selection: $workspace) {
            ForEach(Workspace.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var editingPanel: some View {
        switch workspace {
        case .download:
            OptionsPanelView(options: $draftOptions, onSubmitURL: submitFromURLField)
        case .metadata:
            MetadataPanelView(metadata: $draftMetadata)
        }
    }

    // MARK: - Pending decisions

    /// The oldest job waiting on the user, so several queued jobs are resolved in
    /// order rather than competing for the sheet.
    private var firstPendingDecisionID: UUID? {
        coordinator.jobs.first { $0.state.needsUserDecision }?.id
    }

    private var decisionJob: DownloadJob? {
        guard let decisionJobID else { return nil }
        let job = coordinator.jobs.first { $0.id == decisionJobID }
        // Drop the sheet if the job stopped needing a decision, e.g. it was removed.
        return (job?.state.needsUserDecision ?? false) ? job : nil
    }

    private func present(decisionFor id: UUID) {
        guard let job = coordinator.jobs.first(where: { $0.id == id }) else { return }
        if case .awaitingStreamSelection(let catalog) = job.state {
            // Pre-tick a sensible default — the best video plus every audio and
            // subtitle — which matches what --auto-select would have chosen.
            var initial = Set<String>()
            if let best = catalog.video.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }) {
                initial.insert(best.id)
            }
            initial.formUnion(catalog.audio.map(\.id))
            initial.formUnion(catalog.subtitles.map(\.id))
            streamSelection = initial
        }
        decisionJobID = id
    }

    @ViewBuilder
    private func decisionSheet(for job: DownloadJob) -> some View {
        switch job.state {
        case .awaitingStreamSelection(let catalog):
            StreamSelectionView(
                catalog: catalog,
                selection: $streamSelection,
                onCancel: {
                    coordinator.cancelStreamSelection(id: job.id)
                    decisionJobID = nil
                },
                onConfirm: {
                    coordinator.confirmStreamSelection(id: job.id, selection: streamSelection)
                    decisionJobID = nil
                }
            )
        default:
            EmptyView()
        }
    }

    // MARK: - Persistence

    private func restoreOptions() {
        guard let stored = persistence.load() else { return }
        draftOptions = stored.options
        // Only the reusable metadata fields come back — title, description, date.
        // The paths refer to one finished file, so they are stored empty; a metadata
        // job cannot start until the user picks a file, which its own Run button
        // says plainly right under the fields.
        draftMetadata = stored.metadataDefaults ?? MetadataOptions()
    }

    private func saveOptions() {
        persistence.save(options: draftOptions, metadata: draftMetadata)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(alignment: .center, spacing: 12) {
            IssueList(issues: validationIssues)
            Spacer(minLength: 8)
            Button("Add to queue") { enqueue(start: false) }
                .disabled(!validationIssues.isEmpty)
            Button {
                enqueue(start: true)
            } label: {
                Label(primaryActionTitle, systemImage: primaryActionSymbol)
            }
            .buttonStyle(.borderedProminent)
            // Command-Return rather than the default action, which fired from any text
            // field; plain Return in the URL field is handled by `submitFromURLField`.
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!validationIssues.isEmpty || missingToolHint != nil)
            .help(missingToolHint ?? "Start this job now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Problems with whatever the visible panel is editing.
    ///
    /// Each tab reports only its own, and they are shown next to that tab's buttons.
    /// While the metadata pass was a sub-form of the download panel, its problems
    /// disabled the Download button instead — see `MetadataPanelView`.
    private var validationIssues: [String] {
        switch workspace {
        case .download:
            return CommandBuilder.validate(draftOptions).map(\.message)
        case .metadata:
            return MetadataCommandBuilder.validate(draftMetadata).map(\.message)
        }
    }

    private var primaryActionTitle: String {
        switch workspace {
        case .download: return "Download"
        case .metadata: return "Write metadata"
        }
    }

    private var primaryActionSymbol: String {
        switch workspace {
        case .download: return "arrow.down.circle.fill"
        case .metadata: return "tag.fill"
        }
    }

    /// Why the primary action cannot run, when the tool it needs is missing.
    ///
    /// The two tabs need different tools: a download cannot start without the
    /// engine, and the metadata pass is ffmpeg. Queuing still works in both cases,
    /// so the job is not lost while the user installs what is missing.
    private var missingToolHint: String? {
        switch workspace {
        case .download:
            return coordinator.engineURL == nil
                ? "The download engine is unavailable. The job can still be queued." : nil
        case .metadata:
            return coordinator.ffmpegURL == nil
                ? "ffmpeg is unavailable. The job can still be queued." : nil
        }
    }

    /// Return in the URL field: start the download if it could be started with the button.
    private func submitFromURLField() {
        guard validationIssues.isEmpty, missingToolHint == nil else { return }
        enqueue(start: true)
    }

    private func enqueue(start: Bool) {
        let id: UUID
        switch workspace {
        case .download:
            id = coordinator.addJob(options: draftOptions)
            // Clear only the per-download fields: everything else is usually reused
            // for the next download in a series, and retyping it would be tedious.
            draftOptions.input = ""
            draftOptions.basic.saveName = nil
        case .metadata:
            id = coordinator.addMetadataJob(metadata: draftMetadata)
            // Same reasoning: these two paths name one file, while the title,
            // description and cover carry across a series.
            draftMetadata.inputPath = ""
            draftMetadata.outputPath = ""
        }
        selectedJobID = id
        // Reveal the queue on the way out: a job that was just added is the one
        // thing the user wants to see, and adding into a hidden list looks like
        // nothing happened.
        showsQueue = true
        if start { coordinator.startJob(id: id) }
    }

    // MARK: - Tool status

    /// Explains a missing tool up front rather than letting the user discover it
    /// as a failed download.
    @ViewBuilder
    private var toolStatusBanner: some View {
        if case .failure(let error) = coordinator.engineStatus {
            banner(
                title: error.errorDescription ?? "The download engine is unavailable.",
                detail: error.recoverySuggestion,
                systemImage: "exclamationmark.octagon.fill",
                tint: .red
            )
        } else if case .failure(let error) = coordinator.ffmpegStatus {
            // ffmpeg is only needed for merging and metadata, so this is a warning
            // rather than a blocker: downloading still works without it.
            banner(
                title: error.errorDescription ?? "ffmpeg is unavailable.",
                detail: error.recoverySuggestion,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    private func banner(
        title: String,
        detail: String?,
        systemImage: String,
        tint: Color
    ) -> some View {
        ToolBanner(
            title: title,
            hasDetail: detail != nil,
            systemImage: systemImage,
            tint: tint,
            onShowDetail: {
                if let detail { bannerDetail = BannerDetail(title: title, text: detail) }
            },
            onCheckAgain: { coordinator.refreshToolStatus() }
        )
    }

    // MARK: - Result actions

    /// Highlights a finished job's output in Finder.
    ///
    /// Opens the folder instead when no file can be identified with confidence — see
    /// `DownloadJob.outputFiles`. Showing the right folder beats selecting the wrong file.
    private func reveal(_ job: DownloadJob) {
        let files = job.outputFiles()
        if !files.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        } else if let directory = job.outputDirectory {
            NSWorkspace.shared.open(directory)
        }
    }

    /// Removing a finished or queued job is immediate; removing a running one stops it and
    /// throws away its log, and the trash can sits right beside Stop, so it asks first.
    private func requestRemoval(of job: DownloadJob) {
        if job.state.isRunning || job.isStopping {
            removalCandidateID = job.id
        } else {
            coordinator.removeJob(id: job.id)
        }
    }

    /// Selects the job and opens the drawer, which starts collapsed and so is easy to miss
    /// as the place a failure is explained.
    private func showLog(for id: UUID) {
        selectedJobID = id
        withAnimation(.snappy(duration: 0.2)) { isLogExpanded = true }
    }

    // MARK: - Queue

    private var queue: some View {
        VStack(spacing: 0) {
            Group {
                if coordinator.jobs.isEmpty {
                    emptyQueue
                } else {
                    List(selection: $selectedJobID) {
                        ForEach(coordinator.jobs) { job in
                            JobRowView(
                                job: job,
                                onStart: { coordinator.startJob(id: job.id) },
                                onCancel: { coordinator.cancelJob(id: job.id) },
                                onRemove: { requestRemoval(of: job) },
                                onResolve: { present(decisionFor: job.id) },
                                onReveal: { reveal(job) },
                                onShowLog: { showLog(for: job.id) }
                            )
                            .tag(job.id)
                        }
                    }
                    .listStyle(.inset)
                    // A `List` paints an opaque `textBackgroundColor`, which made the
                    // inspector indistinguishable from the main area — the two columns
                    // read as one white sheet with no boundary between them. Hiding it
                    // lets the material below show through, which is what separates
                    // them.
                    .scrollContentBackground(.hidden)
                }
            }
            // Explicit, because a `List` holding two short rows otherwise sizes to its
            // content and leaves the divider below stranded in the middle of the
            // column, looking like a stray rule.
            .frame(maxHeight: .infinity)

            Divider()
            HStack(spacing: 6) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                Button("Clear finished") { coordinator.clearFinishedJobs() }
                    .controlSize(.small)
                    .disabled(!coordinator.jobs.contains { $0.state.isTerminal })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Fills the column, so the tone reaches the window edges even when the list
        // holds a single short row.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        // A hard edge as well as the tone change: against a light desktop the material
        // on its own is a very faint difference.
        //
        // A `Rectangle`, not a `Divider`: outside a stack a `Divider` still draws
        // *horizontally*, so `.overlay(alignment: .leading) { Divider() }` put a rule
        // straight across the middle of the column — which read as a rendering bug,
        // not as a border.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
        }
    }

    /// Deliberately plain text rather than `ContentUnavailableView`, which sizes its
    /// icon and title for a full-width detail pane and looks oversized in a column
    /// this narrow.
    private var emptyQueue: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("Nothing queued")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(emptyStateDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Points at the panel the user is actually looking at, rather than always
    /// naming the download flow.
    private var emptyStateDescription: String {
        switch workspace {
        case .download: return "Enter a stream URL and choose Download."
        case .metadata: return "Choose a file and write metadata onto it."
        }
    }

    private var summary: String {
        let running = coordinator.jobs.filter(\.state.isRunning).count
        let done = coordinator.jobs.filter { $0.state == .succeeded }.count
        let failed = coordinator.jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count

        var parts: [String] = [
            "\(coordinator.jobs.count) job\(coordinator.jobs.count == 1 ? "" : "s")"
        ]
        if running > 0 { parts.append("\(running) running") }
        if done > 0 { parts.append("\(done) finished") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    private var selectedJob: DownloadJob? {
        guard let selectedJobID else { return nil }
        return coordinator.jobs.first { $0.id == selectedJobID }
    }
}

#Preview("Empty") {
    ContentView(coordinator: DownloadCoordinator())
}

#Preview("With jobs") {
    let coordinator = DownloadCoordinator()

    var options = DownloadOptions()
    options.input = "https://example.com/series/episode-1.m3u8"
    options.basic.saveName = "Episode 1"
    coordinator.addJob(options: options)

    var metadata = MetadataOptions()
    metadata.inputPath = "/Users/me/Movies/episode-1.mp4"
    metadata.outputPath = "/Users/me/Movies/episode-1_meta.mp4"
    metadata.title = "My Show"
    coordinator.addMetadataJob(metadata: metadata)

    return ContentView(coordinator: coordinator)
}
