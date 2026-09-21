import AppKit
import SwiftUI
import GaugeKit

/// A dropdown window for a menu bar item.
///
/// NSPopover draws its own opaque background and arrow, which sits on top of
/// anything the content puts behind itself — Liquid Glass included. A
/// borderless panel with a clear background lets the material be the
/// background, and gives control over the corner radius and shadow that a
/// popover does not offer.
@MainActor
final class PanelWindow: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let hosting: NSHostingView<AnyView>
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onClose: (() -> Void)?

    var isShown: Bool { window.isVisible }

    /// When the panel last closed. Clicking the status item while the panel is
    /// key makes the panel resign key and close before the button's action
    /// runs, so without this the click would immediately reopen it.
    private(set) var closedAt: Date = .distantPast

    /// True while a click on the status item should be treated as the second
    /// half of a close rather than a fresh open.
    var isClosingFromClick: Bool { Date().timeIntervalSince(closedAt) < 0.3 }

    init(content: AnyView) {
        hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]

        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered,
                         defer: true)
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.backgroundColor = .clear
        window.isOpaque = false
        // The SwiftUI content draws the shadow so it can follow the corner radius.
        window.hasShadow = false
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = hosting

        super.init()
        window.delegate = self
    }

    func update(content: AnyView) {
        hosting.rootView = content
        if window.isVisible {
            DispatchQueue.main.async { [weak self] in self?.layout() }
        }
    }

    // MARK: Presentation

    private var anchor: NSStatusBarButton?

    func show(below button: NSStatusBarButton) {
        anchor = button
        layout()
        window.orderFrontRegardless()
        window.makeKey()
        installMonitors()

        // The content measures itself through a GeometryReader, so its real
        // height only exists after a layout pass or two. Without these the
        // window would keep whatever size it guessed first.
        DispatchQueue.main.async { [weak self] in self?.layout() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.layout() }
    }

    /// Sizes the window to its content, never taller than the screen below the
    /// menu bar, and keeps it anchored under its status item.
    private func layout() {
        guard let button = anchor, let buttonWindow = button.window else { return }

        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)

        // A panel taller than the screen would put its lower half out of
        // reach; the content scrolls instead.
        size.height = min(size.height, visible.height - 12)
        size.width = min(size.width, visible.width - 12)
        guard size.width > 1, size.height > 1 else { return }
        window.setContentSize(size)

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = CGPoint(x: buttonFrame.midX - size.width / 2,
                             y: buttonFrame.minY - size.height)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = max(origin.y, visible.minY + 4)
        window.setFrameOrigin(origin)
    }

    /// Used by `--panel`, which has no status item to anchor to.
    func showCentred() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.setContentSize(size)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2,
                                          y: visible.maxY - size.height - 40))
        }
        window.orderFrontRegardless()
        window.makeKey()
    }

    func close() {
        anchor = nil
        guard window.isVisible else { return }
        removeMonitors()
        window.orderOut(nil)
        closedAt = Date()
        onClose?()
    }

    // MARK: Dismissal

    /// A borderless panel gets no automatic light-dismiss, so clicks elsewhere
    /// and the escape key are watched directly.
    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {            // escape
                Task { @MainActor in self?.close() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking another app, or another status item, dismisses the panel.
        guard window.isVisible else { return }
        close()
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
