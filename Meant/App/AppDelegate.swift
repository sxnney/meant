import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let viewModel = MeantViewModel()

    private var overlayController: IntelligenceOverlayController?
    private var hotKeyManager: GlobalHotKeyManager?
    private var contextHotKeyManager: GlobalHotKeyManager?
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var shortcutItem: NSMenuItem?
    private var contextShortcutItem: NSMenuItem?
    private var connectionItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlayController = IntelligenceOverlayController(viewModel: viewModel)

        let manager = GlobalHotKeyManager(identifier: 1) { [weak self] in
            self?.overlayController?.invoke()
        }
        hotKeyManager = manager
        viewModel.shortcutError = manager.register(viewModel.preferences.shortcut)

        let contextManager = GlobalHotKeyManager(identifier: 2) { [weak self] in
            self?.overlayController?.captureContext()
        }
        contextHotKeyManager = contextManager
        viewModel.contextShortcutError = contextManager.register(viewModel.preferences.contextShortcut)

        viewModel.preferences.$shortcut
            .dropFirst()
            .sink { [weak self] shortcut in
                guard let self else { return }
                self.viewModel.shortcutError = self.hotKeyManager?.register(shortcut)
                self.updateShortcutMenuItem()
            }
            .store(in: &cancellables)

        viewModel.preferences.$contextShortcut
            .dropFirst()
            .sink { [weak self] shortcut in
                guard let self else { return }
                self.viewModel.contextShortcutError = self.contextHotKeyManager?.register(shortcut)
                self.updateContextShortcutMenuItem()
            }
            .store(in: &cancellables)

        viewModel.$account
            .combineLatest(viewModel.$model, viewModel.$isConnecting)
            .sink { [weak self] _, _, _ in self?.updateConnectionMenuItem() }
            .store(in: &cancellables)

        configureStatusItem()
        startUpdaterIfConfigured()
        Task { await viewModel.refreshConnection() }

        if !viewModel.preferences.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.openSettings()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        viewModel.refreshSystemState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController?.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        viewModel.loginItem.refresh()
        loginItem?.state = viewModel.loginItem.isEnabled ? .on : .off
        updateConnectionMenuItem()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeMenuBarImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Meant · \(viewModel.preferences.shortcut.displayName)"

        let menu = NSMenu()
        menu.delegate = self

        let use = NSMenuItem(title: "Use Meant on Selection", action: #selector(invoke), keyEquivalent: "")
        use.target = self
        menu.addItem(use)
        shortcutItem = use
        updateShortcutMenuItem()

        let capture = NSMenuItem(title: "Capture Context for Next Refinement", action: #selector(captureContext), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        contextShortcutItem = capture
        updateContextShortcutMenuItem()

        let connection = NSMenuItem(title: "Connecting to Codex…", action: nil, keyEquivalent: "")
        connection.isEnabled = false
        connectionItem = connection
        menu.addItem(connection)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updates.target = updaterController
        updates.isHidden = !hasUpdateFeed
        menu.addItem(updates)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        loginItem = launch
        menu.addItem(launch)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Meant", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private var hasUpdateFeed: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: value),
              url.scheme == "https" else { return false }
        return true
    }

    private func startUpdaterIfConfigured() {
        guard hasUpdateFeed else { return }
        updaterController.startUpdater()
    }

    private func updateShortcutMenuItem() {
        let shortcut = viewModel.preferences.shortcut
        shortcutItem?.keyEquivalent = shortcut.menuKeyEquivalent
        shortcutItem?.keyEquivalentModifierMask = shortcut.cocoaModifiers
        statusItem?.button?.toolTip = "Meant · \(shortcut.displayName)"
    }

    private func updateContextShortcutMenuItem() {
        let shortcut = viewModel.preferences.contextShortcut
        contextShortcutItem?.keyEquivalent = shortcut.menuKeyEquivalent
        contextShortcutItem?.keyEquivalentModifierMask = shortcut.cocoaModifiers
    }

    private func updateConnectionMenuItem() {
        connectionItem?.title = viewModel.connectionLabel
    }

    @objc private func invoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.overlayController?.invoke()
        }
    }

    @objc private func captureContext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.overlayController?.captureContext()
        }
    }

    @objc private func openSettings() {
        let controller: NSWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            let content = NSHostingController(rootView: SettingsView(viewModel: viewModel))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 576, height: 466),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meant Settings"
            window.contentViewController = content
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.setFrameAutosaveName("MeantSettingsWindow")
            window.center()

            controller = NSWindowController(window: window)
            settingsWindowController = controller
        }

        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        viewModel.loginItem.setEnabled(!viewModel.loginItem.isEnabled)
        loginItem?.state = viewModel.loginItem.isEnabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func makeMenuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 2.4, y: 7.1))
            mark.curve(
                to: NSPoint(x: 7.2, y: 5.8),
                controlPoint1: NSPoint(x: 1.3, y: 3.2),
                controlPoint2: NSPoint(x: 6.4, y: 2.7)
            )
            mark.curve(
                to: NSPoint(x: 5.1, y: 13.6),
                controlPoint1: NSPoint(x: 9.1, y: 8.2),
                controlPoint2: NSPoint(x: 2.2, y: 9.2)
            )
            mark.curve(
                to: NSPoint(x: 9.6, y: 6.9),
                controlPoint1: NSPoint(x: 9.6, y: 15.8),
                controlPoint2: NSPoint(x: 12.0, y: 10.1)
            )
            mark.curve(
                to: NSPoint(x: 15.3, y: 6.7),
                controlPoint1: NSPoint(x: 10.4, y: 6.6),
                controlPoint2: NSPoint(x: 12.7, y: 6.7)
            )
            mark.move(to: NSPoint(x: 15.3, y: 5.8))
            mark.line(to: NSPoint(x: 15.3, y: 7.7))
            mark.lineWidth = 1.45
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
