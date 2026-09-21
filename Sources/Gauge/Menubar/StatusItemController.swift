import AppKit
import SwiftUI
import Combine
import GaugeKit

/// Owns one NSStatusItem per enabled module and keeps them in step with the hub.
@MainActor
final class StatusItemController: NSObject {
    private let hub: MonitorHub
    private let settings: GaugeSettings
    private var items: [ModuleID: NSStatusItem] = [:]
    private var panels: [ModuleID: PanelWindow] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var lastRenderedWidth: [ModuleID: CGFloat] = [:]
    private var lastSignature: [ModuleID: String] = [:]

    init(hub: MonitorHub) {
        self.hub = hub
        self.settings = hub.settings
        super.init()
    }



    func start() {
        rebuildItems()

        settings.$modules
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildItems() }
            .store(in: &cancellables)

        // Colour and width changes have to show up without waiting for a tick.
        settings.$graphs
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAll(force: true) }
            .store(in: &cancellables)

        settings.$menubarGraphWidth
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAll(force: true) }
            .store(in: &cancellables)

        // The dropdown's material is baked into its view tree.
        settings.$panel
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for (module, panel) in self.panels {
                    panel.update(content: self.rootView(for: module))
                }
            }
            .store(in: &cancellables)

        // Redraw on every sampling pass.
        hub.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAll() }
            .store(in: &cancellables)

        hub.$weather
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(.weather) }
            .store(in: &cancellables)

        // The clock has to tick even when nothing else changes.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(.time) }
        }

        // Light/dark switches change every colour in the rendered image.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll(force: true) }
        }
    }

    // MARK: Item lifecycle

    private func rebuildItems() {
        let enabled = Set(settings.enabledModules)

        for (module, item) in items where !enabled.contains(module) {
            NSStatusBar.system.removeStatusItem(item)
            items[module] = nil
            panels[module]?.close()
            panels[module] = nil
            lastRenderedWidth[module] = nil
            lastSignature[module] = nil
        }

        // Insertion order decides left-to-right placement within the app's own
        // items, so add them in the configured order.
        for module in settings.enabledModules where items[module] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "gauge.\(module.rawValue)"
            guard let button = item.button else { continue }
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.tag = ModuleID.allCases.firstIndex(of: module) ?? 0
            items[module] = item
        }
        refreshAll(force: true)
    }

    private func module(for button: NSStatusBarButton) -> ModuleID? {
        items.first { $0.value.button === button }?.key
    }

    // MARK: Drawing

    private func refreshAll(force: Bool = false) {
        for module in items.keys { refresh(module, force: force) }
    }

    private func refresh(_ module: ModuleID, force: Bool = false) {
        guard let item = items[module], let button = item.button else { return }
        let style = settings.module(module).style
        let content = MenubarContentBuilder.content(for: module, hub: hub)

        // Setting the image makes AppKit rebuild the item's snapshot, so skip
        // it when nothing visible has changed.
        let signature = "\(style.rawValue)|\(Int(settings.menubarGraphWidth))|\(content.signature)"
        guard force || lastSignature[module] != signature else { return }
        lastSignature[module] = signature

        let image = MenubarRenderer.render(content, style: style,
                                           graphWidth: settings.menubarGraphWidth,
                                           appearance: button.effectiveAppearance)
        button.image = image
        // Width changes as digits come and go; setting it every tick makes the
        // item jitter, so only apply real changes.
        if force || abs((lastRenderedWidth[module] ?? -1) - image.size.width) > 0.5 {
            item.length = image.size.width
            lastRenderedWidth[module] = image.size.width
        }
    }

    // MARK: Interaction

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let module = module(for: sender) else { return }
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondary {
            showContextMenu(for: module, from: sender)
        } else {
            togglePopover(for: module, from: sender)
        }
    }

    private func togglePopover(for module: ModuleID, from button: NSStatusBarButton) {
        // Close any other module's panel first; two open at once is noise.
        for (other, panel) in panels where other != module && panel.isShown {
            panel.close()
        }

        if let existing = panels[module] {
            if existing.isShown {
                existing.close()
                return
            }
            // The click that got here is the one that dismissed the panel.
            if existing.isClosingFromClick { return }
        }

        let panel = panels[module] ?? makePanel(for: module)
        panels[module] = panel
        panel.update(content: rootView(for: module))
        panel.show(below: button)
        hub.isShowingDetail = true
    }

    private func rootView(for module: ModuleID) -> AnyView {
        AnyView(
            ModulePanelView(module: module)
                .environmentObject(hub)
                .environmentObject(settings)
        )
    }

    private func makePanel(for module: ModuleID) -> PanelWindow {
        let panel = PanelWindow(content: rootView(for: module))
        panel.onClose = { [weak self] in
            guard let self else { return }
            if !self.panels.values.contains(where: \.isShown) { self.hub.isShowingDetail = false }
        }
        return panel
    }

    private func showContextMenu(for module: ModuleID, from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "\(module.title) GaugeSettings…", action: #selector(openModuleSettings(_:)), keyEquivalent: "")
            .representedObject = module
        menu.items.last?.target = self
        menu.addItem(.separator())

        let styles = NSMenu()
        for style in MenubarStyle.allCases {
            let entry = NSMenuItem(title: style.title, action: #selector(changeStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [module, style] as [Any]
            entry.state = settings.module(module).style == style ? .on : .off
            styles.addItem(entry)
        }
        let stylesItem = NSMenuItem(title: "Display As", action: nil, keyEquivalent: "")
        stylesItem.submenu = styles
        menu.addItem(stylesItem)

        let hide = NSMenuItem(title: "Hide \(module.title)", action: #selector(hideModule(_:)), keyEquivalent: "")
        hide.target = self
        hide.representedObject = module
        menu.addItem(hide)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Gauge GaugeSettings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit Gauge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        items[module]?.menu = menu
        button.performClick(nil)
        items[module]?.menu = nil
    }

    @objc private func changeStyle(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any],
              let module = pair.first as? ModuleID,
              let style = pair.last as? MenubarStyle else { return }
        settings.setModule(module) { $0.style = style }
        refresh(module, force: true)
    }

    @objc private func hideModule(_ sender: NSMenuItem) {
        guard let module = sender.representedObject as? ModuleID else { return }
        settings.setModule(module) { $0.enabled = false }
    }

    @objc private func openModuleSettings(_ sender: NSMenuItem) {
        let module = sender.representedObject as? ModuleID
        SettingsWindowController.shared.show(hub: hub, selecting: module)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(hub: hub, selecting: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
