import SwiftUI

// The small shared pieces that give both option panels the same look. Kept in one
// file so a tweak lands everywhere at once: when the section headers, warnings and
// footers were styled inline, the Download and Metadata panels drifted apart in
// icon size and text colour within a single edit.

// MARK: - Icon chip

/// A tinted rounded-square badge around an SF Symbol, used to head a section.
///
/// The chip rather than a bare symbol because glyph widths differ wildly —
/// `dot.radiowaves.left.and.right` is roughly three times the width of `tag` — so
/// bare icons leave section titles visibly unaligned down the panel.
struct IconChip: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

// MARK: - Section headers

/// Header for a section that is always shown.
struct PanelSectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            IconChip(systemImage: systemImage, tint: tint)
            Text(title)
                // Fixed font and colour: a SwiftUI `Section` header otherwise
                // inherits a smaller secondary style in some states and not others,
                // so headers in the same Form visibly disagree in size.
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .frame(height: 24)
    }
}

/// Header for a collapsible section, with a chevron that turns as it opens.
struct PanelDisclosureHeader: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                IconChip(systemImage: systemImage, tint: tint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // One rotating chevron rather than swapping the symbol, so the
                    // open and closed states cannot end up different sizes.
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            // A consistent row height, so collapsed headers do not bunch together
            // the way empty Sections otherwise do.
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }
}

// MARK: - Inline problems

/// A problem shown next to the fields that cause it.
struct IssueLabel: View {
    let message: String
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The list of problems shown above an action bar's buttons.
struct IssueList: View {
    let issues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(issues, id: \.self) { issue in
                Label {
                    Text(issue).lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Field help

/// Explanatory text under a control, at a consistent size and colour.
struct FieldFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Chrome") {
    Form {
        Section {
            Text("Always-visible content")
            FieldFootnote("A footnote explaining the field above.")
            IssueLabel(message: "Something needs attention before this can run.")
        } header: {
            PanelSectionHeader(title: "Files", systemImage: "folder", tint: .blue)
        }

        Section {
            EmptyView()
        } header: {
            PanelDisclosureHeader(
                title: "Network",
                systemImage: "network",
                tint: .teal,
                isExpanded: false,
                toggle: {}
            )
        }

        Section {
            IssueList(issues: ["An input file is required.", "An output file is required."])
        } header: {
            PanelSectionHeader(title: "Problems", systemImage: "exclamationmark", tint: .orange)
        }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 360)
}
