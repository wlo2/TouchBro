import Foundation
import ApplicationServices
import AppKit
import Carbon

enum DefaultsKeys {
    static let shortcutKey = "shortcutKey"
    static let shortcutModifiers = "shortcutModifiers"
    static let isEnabled = "isEnabled"
    static let debugLogging = "debugLogging"
    static let excludedApps = "excludedApps"
}

struct ShortcutModifiers: OptionSet {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option  = ShortcutModifiers(rawValue: 1 << 1)
    static let control = ShortcutModifiers(rawValue: 1 << 2)
    static let shift   = ShortcutModifiers(rawValue: 1 << 3)

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    var displayString: String {
        var parts: [String] = []
        if contains(.command) { parts.append("Cmd") }
        if contains(.option) { parts.append("Opt") }
        if contains(.control) { parts.append("Ctrl") }
        if contains(.shift) { parts.append("Shift") }
        return parts.joined(separator: "+")
    }
}

enum Shortcut {
    static let allowedKeys: [String] = (
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { String($0) } +
        ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    )

    // Key positions on a US keyboard, for keys the current layout doesn't have.
    private static let keyCodeMap: [String: CGKeyCode] = [
        "A": 0,  "B": 11, "C": 8,  "D": 2,  "E": 14,
        "F": 3,  "G": 5,  "H": 4,  "I": 34, "J": 38,
        "K": 40, "L": 37, "M": 46, "N": 45, "O": 31,
        "P": 35, "Q": 12, "R": 15, "S": 1,  "T": 17,
        "U": 32, "V": 9,  "W": 13, "X": 7,  "Y": 16,
        "Z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
    ]

    /// The shortcut configured in Settings.
    static var current: (key: String, modifiers: ShortcutModifiers) {
        let defaults = UserDefaults.standard
        let key = (defaults.string(forKey: DefaultsKeys.shortcutKey) ?? "C").uppercased()
        return (key, ShortcutModifiers(rawValue: defaults.integer(forKey: DefaultsKeys.shortcutModifiers)))
    }

    /// Cmd+C is handled by writing the selection to the pasteboard instead of sending keys.
    static var isCopy: Bool {
        let shortcut = current
        return shortcut.key == "C" && shortcut.modifiers == [.command]
    }

    /// Key codes name physical keys, so the key is looked up in the current layout first:
    /// on a German keyboard, the US code for Z types Y.
    static func keyCode(for key: String, command: Bool) -> CGKeyCode? {
        let normalized = key.uppercased()
        return layoutKeyCode(for: normalized, command: command) ?? keyCodeMap[normalized]
    }

    /// The key that types `key` (uppercased) in the layout macOS uses for shortcuts. Main thread only.
    static func layoutKeyCode(for key: String, command: Bool) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        // Layouts can remap keys while Cmd is held; AZERTY puts digits on the number row.
        let modifierState: UInt32 = command ? UInt32(cmdKey >> 8) : 0

        return layoutData.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars
                )
                if status == noErr, String(utf16CodeUnits: chars, count: length).uppercased() == key {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    static func displayString(key: String, modifiers: ShortcutModifiers) -> String {
        let normalized = key.uppercased()
        let modString = modifiers.displayString
        if modString.isEmpty {
            return normalized
        }
        return "\(modString)+\(normalized)"
    }
}

enum ShortcutRunner {
    /// The click may already have cleared the selection, so for Cmd+C the text saved earlier is
    /// written directly; without it, the keys are sent.
    static func postConfiguredShortcut(selectedText: String?) {
        if Shortcut.isCopy, let selectedText, !selectedText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedText, forType: .string)
            return
        }

        let (key, modifiers) = Shortcut.current
        guard let keyCode = Shortcut.keyCode(for: key, command: modifiers.contains(.command)) else { return }
        post(keyCode: keyCode, modifiers: modifiers)
    }

    static func post(keyCode: CGKeyCode, modifiers: ShortcutModifiers) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let flags = modifiers.cgEventFlags
        
        var modifierKeyCodes: [CGKeyCode] = []
        if modifiers.contains(.command) { modifierKeyCodes.append(55) } // kVK_Command
        if modifiers.contains(.option) { modifierKeyCodes.append(58) }  // kVK_Option
        if modifiers.contains(.control) { modifierKeyCodes.append(59) } // kVK_Control
        if modifiers.contains(.shift) { modifierKeyCodes.append(56) }   // kVK_Shift
        
        // 1. Post modifier downs
        for modKey in modifierKeyCodes {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: modKey, keyDown: true) {
                down.post(tap: .cghidEventTap)
            }
        }
        
        // 2. Post main key
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyDown.flags = flags
            keyUp.flags = flags
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        
        // 3. Post modifier ups
        for modKey in modifierKeyCodes.reversed() {
            if let up = CGEvent(keyboardEventSource: source, virtualKey: modKey, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
