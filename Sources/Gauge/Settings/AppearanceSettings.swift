// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import GaugeKit

/// Colour and fill controls for one module's graphs, with a live preview so
/// the effect of a change is visible without closing the window.
struct GraphAppearanceEditor: View {
    let module: ModuleID
    @EnvironmentObject private var settings: GaugeSettings

    private var look: GraphAppearance { settings.graph(module) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview

            HStack(spacing: 18) {
                ColorPicker("Main colour", selection: colorBinding(\.primaryHex), supportsOpacity: false)
                    .frame(width: 150)
                ColorPicker(secondaryLabel, selection: colorBinding(\.secondaryHex), supportsOpacity: false)
                    .frame(width: 170)
            }
            .font(.system(size: 11))

            Picker("Graph", selection: Binding(
                get: { look.shape },
                set: { value in settings.setGraph(module) { $0.shape = value } }
            )) {
                ForEach(GraphShape.allCases.filter { $0.isAvailable(for: module) }, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .frame(width: 300)

            Picker("Fill", selection: Binding(
                get: { look.fade },
                set: { value in settings.setGraph(module) { $0.fade = value } }
            )) {
                ForEach(FadeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 300)

            if look.fade != .outline {
                LabeledContent("Fade strength") {
                    HStack {
                        Slider(value: Binding(
                            get: { look.fadeOpacity },
                            set: { value in settings.setGraph(module) { $0.fadeOpacity = value } }
                        ), in: 0.05...1)
                        .frame(width: 180)
                        Text("\(Int(look.fadeOpacity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Toggle("Draw the line along the top", isOn: Binding(
                get: { look.showsLine },
                set: { value in settings.setGraph(module) { $0.showsLine = value } }
            ))

            Toggle("Colour the value by load (green → red)", isOn: Binding(
                get: { look.usesLoadColor },
                set: { value in settings.setGraph(module) { $0.usesLoadColor = value } }
            ))
            .help("When off, the value uses the main colour above.")

            HStack {
                Button("Reset to default") { settings.resetGraph(module) }
                    .controlSize(.small)
                Text(look.primaryHex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    /// Only the modules that draw two series need the second colour explained.
    private var secondaryLabel: String {
        switch module {
        case .network: "Upload colour"
        case .disks: "Write colour"
        default: "Second colour"
        }
    }

    private var preview: some View {
        HistoryGraph(
            plots: [Plot(values: Self.sampleSeries, color: look.primary),
                    Plot(values: Self.secondarySeries, color: look.secondary)],
            shape: look.shape,
            ceiling: look.shape == .stacked ? 1.4 : 1,
            height: 58,
            appearance: look
        )
        .frame(maxWidth: .infinity)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<GraphAppearance, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: settings.graph(module)[keyPath: keyPath]) },
            set: { newValue in
                guard let hex = newValue.hexString else { return }
                settings.setGraph(module) { $0[keyPath: keyPath] = hex }
            }
        )
    }

    /// A shape with a peak and a dip, so every fill style is distinguishable.
    private static let sampleSeries: [Double] = (0..<48).map { index in
        let x = Double(index) / 47
        return (0.25 + 0.55 * sin(x * .pi * 1.6) + 0.12 * sin(x * .pi * 7)).clamped(to: 0.02...1)
    }

    private static let secondarySeries: [Double] = (0..<48).map { index in
        let x = Double(index) / 47
        return (0.15 + 0.3 * sin(x * .pi * 2.4 + 1)).clamped(to: 0.02...1)
    }
}

extension Color {
    /// sRGB hex for storage. Returns nil for colours that cannot be converted,
    /// rather than silently writing something wrong.
    var hexString: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return RGBAColor(red: Double(srgb.redComponent),
                         green: Double(srgb.greenComponent),
                         blue: Double(srgb.blueComponent),
                         alpha: Double(srgb.alphaComponent)).hex
    }
}

/// Controls for the dropdown's own background — the glass, its tint, and the
/// shape it is cut to.
struct PanelBackgroundEditor: View {
    @EnvironmentObject private var settings: GaugeSettings

    private var panel: PanelAppearance { settings.panel }

    private func update(_ transform: (inout PanelAppearance) -> Void) {
        var value = settings.panel
        transform(&value)
        settings.panel = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview

            Picker("Material", selection: Binding(
                get: { panel.material },
                set: { value in update { $0.material = value } }
            )) {
                ForEach(PanelMaterial.available, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(width: 320)

            Text(materialExplanation)
                .settingsFootnote()

            HStack(spacing: 14) {
                ColorPicker("Tint", selection: Binding(
                    get: { Color(hex: panel.tintHex.isEmpty ? "#7F7F7F" : panel.tintHex) },
                    set: { value in
                        guard let hex = value.hexString else { return }
                        update { $0.tintHex = hex }
                    }
                ), supportsOpacity: false)
                .frame(width: 110)
                .font(.system(size: 11))

                Button("No tint") { update { $0.tintHex = "" } }
                    .controlSize(.small)
                    .disabled(panel.tintHex.isEmpty)
            }

            LabeledContent("Tint strength") {
                HStack {
                    Slider(value: Binding(
                        get: { panel.tintStrength },
                        set: { value in update { $0.tintStrength = value } }
                    ), in: 0...0.8)
                    .frame(width: 180)
                    Text("\(Int(panel.tintStrength * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .disabled(panel.tintHex.isEmpty)

            LabeledContent("Corner radius") {
                HStack {
                    Slider(value: Binding(
                        get: { panel.cornerRadius },
                        set: { value in update { $0.cornerRadius = value } }
                    ), in: 0...28, step: 1)
                    .frame(width: 180)
                    Text("\(Int(panel.cornerRadius)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
            }

            LabeledContent("Shadow") {
                HStack {
                    Slider(value: Binding(
                        get: { panel.shadowStrength },
                        set: { value in update { $0.shadowStrength = value } }
                    ), in: 0...0.8)
                    .frame(width: 180)
                    Text("\(Int(panel.shadowStrength * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Toggle("Hairline edge", isOn: Binding(
                get: { panel.showsBorder },
                set: { value in update { $0.showsBorder = value } }
            ))

            if panel.material.usesGlass {
                Toggle("Glass reacts to the pointer", isOn: Binding(
                    get: { panel.interactive },
                    set: { value in update { $0.interactive = value } }
                ))
                .help("The material brightens and shifts under the cursor.")
            }

            Button("Reset background") { settings.panel = .standard }
                .controlSize(.small)
        }
    }

    private var materialExplanation: String {
        switch panel.material {
        case .liquidGlass:
            "The macOS 26 material: it refracts what is behind the panel. Tint colours the glass itself."
        case .clearGlass:
            "Clearer glass — more of the desktop shows through, so a tint helps text stay readable."
        case .vibrant:
            "The blur system menus used before Liquid Glass."
        case .opaque:
            "A plain fill. The most readable option over busy windows."
        }
    }

    /// Glass only looks like anything over something, so the preview sits on a
    /// patterned backdrop rather than the settings window's own grey.
    private var preview: some View {
        ZStack {
            LinearGradient(colors: [.purple, .blue, .teal, .orange],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 8) {
                ForEach(0..<7) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.25))
                        .frame(width: 14)
                        .offset(y: CGFloat(index % 3) * 8)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("CPU")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("48%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                HStack {
                    Text("Memory").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text("11.6 GB").font(.system(size: 10, design: .monospaced))
                }
                .frame(width: 130)
            }
            .padding(12)
            .panelChrome(panel)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - The Appearance page

struct AppearanceSettingsPage: View {
    @EnvironmentObject private var settings: GaugeSettings
    @StateObject private var selected = UIState(ModuleID.cpu)

    var body: some View {
        SettingsGroup("Menu bar") {
            LabeledContent("Graph width") {
                HStack {
                    Slider(value: $settings.menubarGraphWidth, in: 16...80, step: 2)
                        .frame(width: 180)
                    Text("\(Int(settings.menubarGraphWidth)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Text("Applies to every module drawn as a graph.")
                .settingsFootnote()
        }

        SettingsGroup("Popup background") {
            PanelBackgroundEditor()
            Divider().padding(.vertical, 2)
            Toggle("Highlight rows under the pointer", isOn: $settings.highlightRowsOnHover)
        }

        SettingsGroup("Graph colours") {
            Picker("Module", selection: $selected.value) {
                ForEach(ModuleID.allCases) { module in
                    Text(module.title).tag(module)
                }
            }
            .frame(width: 220)

            GraphAppearanceEditor(module: selected.value)

            Divider().padding(.vertical, 2)

            HStack {
                Button("Reset every module") {
                    for module in ModuleID.allCases { settings.resetGraph(module) }
                }
                .controlSize(.small)
                Spacer()
            }
        }
    }
}
