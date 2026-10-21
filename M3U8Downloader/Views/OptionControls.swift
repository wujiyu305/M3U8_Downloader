import AppKit
import SwiftUI

// MARK: - Tri-state toggle

/// A toggle over an `Bool?` with three meanings: unset, on, off.
///
/// A plain `Toggle` cannot express this, and collapsing the three states into two
/// would break the option model: `CommandBuilder` emits an argument **only** when a
/// value is non-nil, which is what keeps the engine's own defaults in effect. With
/// a two-state toggle every option would be sent on every run, and
/// `--thread-count` would be pinned to whatever number the UI happened to show
/// instead of the engine's machine-dependent default.
struct TristateToggle: View {
    let label: String
    @Binding var value: Bool?
    /// Shown as the "Default" option's detail, so the user can see what leaving it
    /// unset actually does.
    let engineDefault: Bool

    var body: some View {
        Picker(label, selection: $value) {
            Text("Default (\(engineDefault ? "on" : "off"))").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
        .pickerStyle(.menu)
    }
}

// MARK: - Optional text

/// A text field bound to an `String?`, where empty text means unset.
struct OptionalTextField: View {
    let title: String
    @Binding var text: String?
    var prompt: String?

    init(_ title: String, text: Binding<String?>, prompt: String? = nil) {
        self.title = title
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        TextField(
            title,
            text: Binding(
                get: { text ?? "" },
                // Normalise empty input back to nil so an option the user typed
                // into and then cleared does not linger as an empty argument.
                set: { text = $0.isEmpty ? nil : $0 }
            ),
            prompt: prompt.map { Text($0) }
        )
    }
}

/// A numeric field bound to an `Int?`, where empty means unset.
struct OptionalIntField: View {
    let label: String
    @Binding var value: Int?
    let placeholder: String
    let range: ClosedRange<Int>

    @State private var text: String = ""

    var body: some View {
        TextField(label, text: $text, prompt: Text(placeholder))
            .onAppear { text = value.map(String.init) ?? "" }
            .onChange(of: text) { _, newValue in
                guard !newValue.isEmpty else {
                    value = nil
                    return
                }
                // Ignore unparseable or out-of-range input rather than clamping it:
                // silently changing a number the user typed is more confusing than
                // leaving the previous value in place.
                if let parsed = Int(newValue), range.contains(parsed) {
                    value = parsed
                }
            }
            .onChange(of: value) { _, newValue in
                let expected = newValue.map(String.init) ?? ""
                if text != expected, Int(text) != newValue { text = expected }
            }
    }
}

// MARK: - Paths

/// A text field with a Browse button for choosing a directory.
struct DirectoryField: View {
    let label: String
    @Binding var path: String?
    let placeholder: String

    var body: some View {
        HStack {
            OptionalTextField(label, text: $path, prompt: placeholder)
            Button("Browse…") { choose() }
                .buttonStyle(.borderless)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

/// A text field with a Browse button for choosing a file.
struct FileField: View {
    let label: String
    @Binding var path: String

    var body: some View {
        HStack {
            TextField(label, text: $path)
            Button("Browse…") { choose() }
                .buttonStyle(.borderless)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

// MARK: - Headers

/// Editor for the request headers sent as repeated `-H` arguments.
///
/// Cookie and User-Agent are offered as presets because they are the two headers
/// this tool is almost always used with, but they are stored as ordinary headers —
/// no special-casing in the model, so nothing can disagree about their spelling.
struct HeaderListEditor: View {
    @Binding var headers: [DownloadOptions.Network.Header]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Headers")
                Spacer()
                Menu("Add") {
                    Button("Cookie") { add(name: "Cookie") }
                    Button("User-Agent") { add(name: "User-Agent") }
                    Button("Referer") { add(name: "Referer") }
                    Divider()
                    Button("Custom…") { add(name: "") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ForEach($headers) { $header in
                HStack(spacing: 4) {
                    TextField("Name", text: $header.name)
                        .frame(width: 110)
                    TextField("Value", text: $header.value)
                    Button("Remove", systemImage: "minus.circle") {
                        headers.removeAll { $0.id == header.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func add(name: String) {
        headers.append(.init(name: name, value: ""))
    }
}

// MARK: - Keys

/// Editor for `--key` values, one per decryption key.
struct KeyListEditor: View {
    @Binding var keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Decryption keys")
                Spacer()
                Button("Add", systemImage: "plus.circle") { keys.append("") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }

            ForEach(keys.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    TextField("KID:KEY", text: keyBinding(at: index))
                        .font(.system(.body, design: .monospaced))
                    Button("Remove", systemImage: "minus.circle") {
                        keys.remove(at: index)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    /// Index-based binding guarded against a stale index, which can happen when a
    /// row is removed while the field still holds focus.
    private func keyBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < keys.count ? keys[index] : "" },
            set: { newValue in
                guard index < keys.count else { return }
                keys[index] = newValue
            }
        )
    }
}

// MARK: - Extra arguments

/// Free-form extra engine arguments.
///
/// The engine has around 70 options and this panel surfaces the useful subset, so
/// this field is what stops the GUI from being a hard ceiling. Input is split on
/// whitespace while respecting quotes, matching how a shell would tokenise it —
/// otherwise a path with a space would silently become two arguments.
struct ExtraArgumentsField: View {
    @Binding var arguments: [String]
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Value-only monospacing, as in `SettingsView`: `.font` on the field itself
            // would restyle its "Extra arguments" label as well.
            LabeledContent("Extra arguments") {
                TextField(
                    "Extra arguments", text: $text,
                    prompt: Text("--custom-range 00:00-10:00"), axis: .vertical
                )
                .labelsHidden()
                .lineLimit(1...3)
                .font(.system(.body, design: .monospaced))
                .onAppear {
                    // Only seed an empty field. `text` is `@State`, so it is empty again
                    // on every re-appearance (a collapsed section, another tab, a restart),
                    // and the write below fires `onChange`.
                    if text.isEmpty { text = Self.render(arguments) }
                }
                .onChange(of: text) { _, newValue in
                    // Skip the echo of our own seeding: the arguments are already right,
                    // and re-tokenising their rendering is what used to split `A B`.
                    let parsed = Self.tokenize(newValue)
                    if parsed != arguments { arguments = parsed }
                }
            }

            if !arguments.isEmpty {
                Text("\(arguments.count) argument\(arguments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The inverse of `tokenize` for every token it can produce, so
    /// `tokenize(render(x)) == x` for those.
    ///
    /// 🔴 Joining with a space alone is not an inverse. `["-H", "A B"]` came back as
    /// `["-H", "A", "B"]` the next time the section appeared, silently changing the
    /// command that ran.
    ///
    /// A token with no `"` is wrapped in double quotes. One that has `"` cannot be, and
    /// single quotes alone fail if it also has `'`, so it is built from adjacent pieces,
    /// which `tokenize` joins back into one token: each run of other characters in double
    /// quotes, each `"` as `'"'`. (An empty token is not representable — `tokenize` never
    /// produces one.)
    static func render(_ arguments: [String]) -> String {
        arguments.map { quoted($0) }.joined(separator: " ")
    }

    private static func quoted(_ token: String) -> String {
        guard token.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else {
            return token
        }
        var result = ""
        var run = ""
        func flushRun() {
            if !run.isEmpty { result += "\"\(run)\"" }
            run = ""
        }
        for character in token {
            if character == "\"" {
                flushRun()
                result += "'\"'"
            } else {
                run.append(character)
            }
        }
        flushRun()
        return result
    }

    /// Splits on whitespace, honouring single and double quotes.
    ///
    /// Deliberately simple: it does not expand variables or globs, because these
    /// tokens go straight to `Process` and are never interpreted by a shell.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for character in input {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
