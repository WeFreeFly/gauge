// SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import GaugeKit

/// A single reusable settings window. The app is an accessory, so opening it
/// has to temporarily give the process a regular activation policy or the
/// window cannot take focus.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(hub: MonitorHub, selecting module: ModuleID?) {
        if window == nil {
            let root = SettingsView(initialSelection: module.map { SettingsSection.module($0) })
                .environmentObject(hub)
                .environmentObject(hub.settings)

            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Gauge Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 660, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only once the window goes away.
        NSApp.setActivationPolicy(.accessory)
    }
}
