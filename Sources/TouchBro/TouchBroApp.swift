import SwiftUI
import AppKit

@main
struct TouchBroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = ForceClickMonitor()
    private var statusItem: NSStatusItem?
    private var enabledItem: NSMenuItem?
    private var shortcutInfoItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDefaults()
        _ = monitor
        setupStatusItem()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !Permissions.allRequiredGranted else { return }
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func toggleEnabled() {
        let defaults = UserDefaults.standard
        let current = defaults.bool(forKey: DefaultsKeys.isEnabled)
        defaults.set(!current, forKey: DefaultsKeys.isEnabled)
        refreshMenuState()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func registerDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            DefaultsKeys.shortcutKey: "C",
            DefaultsKeys.shortcutModifiers: ShortcutModifiers.command.rawValue,
            DefaultsKeys.isEnabled: true,
            DefaultsKeys.debugLogging: false,
            DefaultsKeys.excludedApps: ["com.apple.finder"]
        ])

        if defaults.object(forKey: DefaultsKeys.isEnabled) == nil {
            defaults.set(true, forKey: DefaultsKeys.isEnabled)
        }
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "TouchBro")
            button.image?.isTemplate = true
            button.toolTip = "TouchBro"
        }

        let menu = NSMenu()
        menu.delegate = self

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        self.enabledItem = enabledItem
        menu.addItem(enabledItem)

        let shortcutInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        shortcutInfoItem.isEnabled = false
        self.shortcutInfoItem = shortcutInfoItem
        menu.addItem(shortcutInfoItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TouchBro", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        let defaults = UserDefaults.standard
        let isEnabled = defaults.bool(forKey: DefaultsKeys.isEnabled)
        enabledItem?.state = isEnabled ? .on : .off

        let key = defaults.string(forKey: DefaultsKeys.shortcutKey) ?? "C"
        let modifiersRaw = defaults.integer(forKey: DefaultsKeys.shortcutModifiers)
        let modifiers = ShortcutModifiers(rawValue: modifiersRaw)
        let display = Shortcut.displayString(key: key, modifiers: modifiers)
        shortcutInfoItem?.title = "Force Click -> \(display)"
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() { }

    func show() {
        DispatchQueue.main.async {
            if self.window == nil {
                self.window = self.makeWindow()
            }

            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.orderFrontRegardless()
        }
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TouchBro Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 620))
        window.minSize = NSSize(width: 520, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
