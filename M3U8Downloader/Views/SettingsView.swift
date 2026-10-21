import AppKit
import SwiftUI

/// Lets the user point the app at specific engine and ffmpeg binaries.
///
/// `ToolLocator` has always honoured an override, but nothing could set it, so its
/// error messages promised a Settings screen that did not exist. This is that
/// screen; the keys written here are exactly `ToolLocator.Tool.overrideDefaultsKey`,
/// so a value set here is what discovery picks up.
struct SettingsView: View {
    /// Same coordinator as the main window, so clearing an override immediately
    /// updates the banner instead of requiring a relaunch.
    var coordinator: DownloadCoordinator

    // Bound straight to the keys ToolLocator reads. Using @AppStorage rather than a
    // local copy means there is no second source of truth to fall out of sync.
    @AppStorage("enginePathOverride") private var enginePath: String = ""
    @AppStorage("ffmpegPathOverride") private var ffmpegPath: String = ""

    var body: some View {
        Form {
            Section {
                toolRow(
                    title: "Download engine",
                    path: $enginePath,
                    status: coordinator.engineStatus,
                    allowedNote: "N_m3u8DL-RE"
                )
            } header: {
                Text("N_m3u8DL-RE")
            } footer: {
                Text(
                    "Normally the engine is bundled with the app. Set a path here to "
                        + "use a different build."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                toolRow(
                    title: "ffmpeg",
                    path: $ffmpegPath,
                    status: coordinator.ffmpegStatus,
                    allowedNote: "ffmpeg"
                )
            } header: {
                Text("ffmpeg")
            } footer: {
                Text(
                    "ffmpeg is not bundled. The app looks in /opt/homebrew/bin, "
                        + "/usr/local/bin and /opt/local/bin, which is why a Homebrew "
                        + "install is found even though a windowed app does not inherit "
                        + "your shell's PATH."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
        // Re-run discovery whenever an override changes, so the status line below
        // each field reflects the new value rather than a stale result.
        .onChange(of: enginePath) { _, _ in coordinator.refreshToolStatus() }
        .onChange(of: ffmpegPath) { _, _ in coordinator.refreshToolStatus() }
    }

    @ViewBuilder
    private func toolRow(
        title: String,
        path: Binding<String>,
        status: Result<ToolLocator.Resolved, ToolLocator.LocateError>,
        allowedNote: String
    ) -> some View {
        // `LabeledContent` so the monospaced font lands on the *value* only. Putting `.font`
        // on a `TextField` restyles its title too: the labels "Download engine" and "ffmpeg"
        // came out in a monospaced face, as if they were paths.
        LabeledContent(title) {
            HStack {
                TextField(title, text: path, prompt: Text("Automatic"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                Button("Choose…") { choose(into: path) }
                Button("Clear") { path.wrappedValue = "" }
                    .disabled(path.wrappedValue.isEmpty)
            }
        }

        statusLine(for: status)
    }

    /// Shows what discovery actually resolved, including *how* it was found — the
    /// difference between a bundled engine and a user override matters when
    /// something behaves unexpectedly.
    @ViewBuilder
    private func statusLine(
        for status: Result<ToolLocator.Resolved, ToolLocator.LocateError>
    ) -> some View {
        switch status {
        case .success(let resolved):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resolved.url.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text(describe(resolved.source))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .failure(let error):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error.errorDescription ?? "Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func describe(_ source: ToolLocator.Source) -> String {
        switch source {
        case .userOverride: return "From the path set here"
        case .appBundle: return "Bundled with the app"
        case .knownLocation: return "Found in a standard install location"
        case .searchPath: return "Found on PATH"
        }
    }

    private func choose(into path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
        }
    }
}

#Preview {
    SettingsView(coordinator: DownloadCoordinator())
}
