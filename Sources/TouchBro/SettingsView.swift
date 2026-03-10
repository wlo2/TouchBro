import SwiftUI
import ApplicationServices
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

extension Notification.Name {
    static let touchBroPermissionsChanged = Notification.Name("TouchBroPermissionsChanged")
}

struct SettingsView: View {
    @AppStorage(DefaultsKeys.shortcutKey) private var shortcutKey = "C"
    @AppStorage(DefaultsKeys.shortcutModifiers) private var shortcutModifiers = ShortcutModifiers.command.rawValue
    @AppStorage(DefaultsKeys.isEnabled) private var isEnabled = true
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    private var modifiers: ShortcutModifiers {
        ShortcutModifiers(rawValue: shortcutModifiers)
    }

    private var shortcutDisplay: String {
        Shortcut.displayString(key: shortcutKey, modifiers: modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Force Click Action")
                .font(.title2)
                .bold()

            Toggle("Enabled", isOn: $isEnabled)

            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcut")
                    .font(.headline)

                Text("Current: \(shortcutDisplay)")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Picker("Key", selection: $shortcutKey) {
                        ForEach(Shortcut.allowedKeys, id: \.self) { key in
                            Text(key).tag(key)
                        }
                    }
                    .frame(width: 90)

                    Toggle("Cmd", isOn: binding(for: .command))
                    Toggle("Opt", isOn: binding(for: .option))
                    Toggle("Ctrl", isOn: binding(for: .control))
                    Toggle("Shift", isOn: binding(for: .shift))
                }
            }

            Divider()

            PermissionsView()

            Divider()
            
            ExceptionsView()
            
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start With macOS", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        launchAtLoginEnabled = LaunchAtLogin.setEnabled(newValue)
                    }
                ))
            }

            Divider()

            VStack(spacing: 6) {
                Text("gggggJJJJJJJJJJJJJEEEEEEEBBBBbbbBDDDDDDDDdddddddDDDDT Industries 2026")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Link("GitHub", destination: URL(string: "https://github.com/wlo2/TouchBro")!)
                    .font(.footnote)

                Text("v1.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(width: 520, alignment: .topLeading)
        .onAppear {
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
        }
    }

    private func binding(for modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding(
            get: { modifiers.contains(modifier) },
            set: { newValue in
                var updated = modifiers
                if newValue {
                    updated.insert(modifier)
                } else {
                    updated.remove(modifier)
                }
                shortcutModifiers = updated.rawValue
            }
        )
    }
}

private struct PermissionsView: View {
    @State private var accessibilityGranted = Permissions.accessibilityGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.headline)

            HStack {
                Text("Accessibility")
                Spacer()
                Text(accessibilityGranted ? "Granted" : "Needed")
                    .foregroundStyle(accessibilityGranted ? .green : .red)
            }

            HStack(spacing: 12) {
                Button("Request Accessibility") {
                    Permissions.requestAccessibility()
                    refresh()
                }
            }
            .buttonStyle(.bordered)

            Text("TouchBro uses mouse event taps, so Input Monitoring is not required.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("After granting Accessibility, return to TouchBro and status will auto-refresh.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        accessibilityGranted = Permissions.accessibilityGranted
    }
}

private struct ExceptionsView: View {
    @State private var excludedApps: [String] = []
    @State private var selection: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exceptions")
                .font(.headline)
            
            Text("TouchBro will not trigger in these applications:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            
            List(selection: $selection) {
                ForEach(excludedApps, id: \.self) { bundleId in
                    Text(bundleId)
                }
            }
            .frame(height: 100)
            .border(Color.secondary.opacity(0.2))
            
            HStack(spacing: 12) {
                Button("+ Add App") {
                    DispatchQueue.main.async {
                        let panel = NSOpenPanel()
                        if #available(macOS 11.0, *) {
                            panel.allowedContentTypes = [.application]
                        } else {
                            panel.allowedFileTypes = ["app"]
                        }
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        
                        NSApp.activate(ignoringOtherApps: true)
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            if let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier {
                                if !excludedApps.contains(bundleId) {
                                    excludedApps.append(bundleId)
                                    save()
                                }
                            }
                        }
                    }
                }
                
                Button("- Remove Selected") {
                    if let sel = selection {
                        excludedApps.removeAll { $0 == sel }
                        selection = nil
                        save()
                    }
                }
                .disabled(selection == nil)
            }
        }
        .onAppear {
            load()
        }
    }
    
    private func load() {
        excludedApps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.excludedApps) ?? []
    }
    
    private func save() {
        UserDefaults.standard.set(excludedApps, forKey: DefaultsKeys.excludedApps)
    }
}

enum Permissions {
    static var allRequiredGranted: Bool {
        accessibilityGranted
    }

    static var accessibilityGranted: Bool {
        // Some macOS versions report trusted status through only one of these APIs.
        if AXIsProcessTrusted() {
            return true
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibility() {
        guard !accessibilityGranted else { return }
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
        NotificationCenter.default.post(name: .touchBroPermissionsChanged, object: nil)
    }

}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return SMAppService.mainApp.status == .enabled
        }
        return SMAppService.mainApp.status == .enabled
    }
}
