import SwiftUI
import GaugeKit

/// Chooses which readings a menu bar item shows.
///
/// Sensors and Combined offer different readings from different sources, but
/// the control is the same, so they hand this view a list of rows rather than
/// each growing its own copy.
struct MenubarReadingPicker: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        /// Used in the one-line summary, where the full titles would not fit.
        let shortTitle: String
        /// The current reading, or nil when this Mac does not report it.
        let value: String?
        /// Shown in place of a value; nil means simply unavailable.
        let unavailableReason: String?
        let isSelected: Bool
        let toggle: () -> Void

        var isAvailable: Bool { value != nil }
    }

    enum Style { case compact, full }

    var style: Style = .compact
    var rows: [Row]
    var maximum: Int
    var reset: () -> Void

    private var selected: [Row] { rows.filter(\.isSelected) }

    private var summary: String {
        selected.isEmpty ? "nothing" : selected.map(\.shortTitle).joined(separator: " · ")
    }

    var body: some View {
        switch style {
        case .compact: compact
        case .full: full
        }
    }

    // MARK: In the dropdown

    private var compact: some View {
        HStack(spacing: 6) {
            Text("MENU BAR")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.5)
            Menu {
                ForEach(rows) { row in
                    Button(action: row.toggle) {
                        if row.isSelected {
                            Label(row.title, systemImage: "checkmark")
                        } else {
                            Text(row.title)
                        }
                    }
                    .disabled(!row.isAvailable && !row.isSelected)
                }
                Divider()
                Text("Up to \(maximum) at a time")
            } label: {
                Text(summary)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .help("Choose what this menu bar item shows")
            Spacer(minLength: 0)
        }
    }

    // MARK: In settings

    private var full: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(explanation)
                .settingsFootnote()

            ForEach(rows) { row in
                Toggle(isOn: Binding(get: { row.isSelected }, set: { _ in row.toggle() })) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(.system(size: 11))
                        Spacer(minLength: 8)
                        if let value = row.value {
                            Text(value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(row.unavailableReason ?? "not reported")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(!row.isAvailable && !row.isSelected)
            }

            HStack {
                Button("Reset to default", action: reset)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private var explanation: String {
        maximum <= 2
            ? "Pick up to \(maximum) readings. One shows at full size; two stack at a smaller "
            + "one. Greyed-out readings are not reported by this Mac."
            : "Pick up to \(maximum) readings. They are laid out two to a line. Greyed-out "
            + "readings are not reported by this Mac."
    }
}
