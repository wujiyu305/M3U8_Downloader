import AppKit
import SwiftUI

/// The window's bottom log drawer: the selected job's engine output and the exact
/// command that ran.
///
/// **Collapsed by default.** When collapsed it is a single bar showing what it would
/// reveal, which is the whole reason it is a drawer: the log only matters when
/// something goes wrong, so it should not permanently occupy a third of the window.
///
/// The disclosure control lives in this view rather than in a wrapper so that the
/// collapsed state is *one* bar. A separate header owned by the caller, stacked on top
/// of this view's own Log/Command bar, put two full-width bars across the bottom of
/// the window when expanded.
struct JobDetailView: View {
    /// The selected job, or `nil` when nothing is selected. Optional so the drawer can
    /// still be shown and expanded with an empty queue, rather than appearing and
    /// disappearing as the selection changes and shifting the whole layout.
    let job: DownloadJob?
    @Binding var isExpanded: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case log = "Log"
        case command = "Command"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .log

    /// Roughly a dozen log lines: enough to read a failure without the drawer taking
    /// over the window it is meant to stay out of the way of.
    private static let expandedHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                Divider()
                content
                    .frame(height: Self.expandedHeight)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // The title is dropped once the Log/Command picker appears, which
                    // otherwise reads "Log | Log | Command".
                    if !isExpanded {
                        Text("Log")
                            .font(.callout.weight(.medium))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the log" : "Show the log")

            if isExpanded {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let job {
                Text(job.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No job selected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            // Collapsed, the record count is the only hint that there is anything to
            // look at — without it the drawer gives no reason to open it.
            if !isExpanded, let job, !job.log.records.isEmpty {
                Text("\(job.log.records.count) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if isExpanded {
                copyButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private var copyButton: some View {
        switch tab {
        case .log:
            Button("Copy log", systemImage: "doc.on.doc") {
                copyToPasteboard(job?.log.plainText() ?? "")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .disabled(job?.log.records.isEmpty ?? true)
        case .command:
            Button("Copy command", systemImage: "doc.on.doc") {
                copyToPasteboard(job?.executedCommand ?? "")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .disabled(job?.executedCommand == nil)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let job {
            switch tab {
            case .log: logView(for: job)
            case .command: commandView(for: job)
            }
        } else {
            Text("Select a job in the queue to see its output.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Log

    private func logView(for job: DownloadJob) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if job.log.isTruncated {
                        Text("… \(job.log.droppedCount) earlier records dropped …")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                    if job.log.records.isEmpty {
                        Text("No output yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(job.log.records.enumerated()), id: \.offset) { item in
                        logLine(item.element)
                            .id(item.offset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .textSelection(.enabled)
            }
            // Follow the tail as new records arrive, which is what you want
            // while watching a download.
            .onChange(of: job.log.records.count) { _, count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func logLine(_ record: EngineOutputParser.LogRecord) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(record.timestamp)
                .foregroundStyle(.tertiary)
            Text(record.level.rawValue)
                .foregroundStyle(color(for: record.level))
                .frame(width: 42, alignment: .leading)
            Text(record.message)
                .foregroundStyle(record.level == .error ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func color(for level: EngineOutputParser.Level) -> Color {
        switch level {
        case .error: return .red
        case .warn: return .orange
        case .info: return .secondary
        // `.tertiary` is a ShapeStyle, not a Color, so DEBUG/EXTRA use a dimmed
        // secondary instead of the hierarchical style.
        case .debug, .extra: return .secondary.opacity(0.6)
        }
    }

    // MARK: - Command

    private func commandView(for job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = job.executedCommand {
                Text("This is the command that ran:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator)
                )
            } else {
                // Before the first run there is no executed command. Showing a
                // preview built from the current options would be a different
                // string from whatever eventually runs, so say so plainly instead.
                Text("The exact command appears here once this job has been started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// A job carrying a few log records, for the previews below.
private func sampleJob() -> DownloadJob {
    var options = DownloadOptions()
    options.input = "https://example.com/stream.m3u8"
    options.basic.saveName = "Episode 1"

    var job = DownloadJob(options: options)
    job.log.append(
        .init(timestamp: "10:24:55.715", level: .info, message: "N_m3u8DL-RE (Beta version)"))
    job.log.append(
        .init(
            timestamp: "10:24:55.718", level: .info, message: "Content Matched: HTTP Live Streaming"
        ))
    job.log.append(.init(timestamp: "10:24:55.720", level: .warn, message: "Writing meta json"))
    job.log.append(
        .init(timestamp: "10:24:58.737", level: .error, message: "Download first segment failed!"))
    return job
}

#Preview("Collapsed") {
    @Previewable @State var isExpanded = false

    VStack(spacing: 0) {
        Color.clear
        Divider()
        JobDetailView(job: sampleJob(), isExpanded: $isExpanded)
    }
    .frame(width: 620, height: 200)
}

#Preview("Expanded") {
    @Previewable @State var isExpanded = true

    VStack(spacing: 0) {
        Color.clear
        Divider()
        JobDetailView(job: sampleJob(), isExpanded: $isExpanded)
    }
    .frame(width: 620, height: 360)
}

#Preview("Nothing selected") {
    @Previewable @State var isExpanded = true

    VStack(spacing: 0) {
        Color.clear
        Divider()
        JobDetailView(job: nil, isExpanded: $isExpanded)
    }
    .frame(width: 620, height: 360)
}
