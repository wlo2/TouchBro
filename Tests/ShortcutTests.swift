import Testing
@testable import TouchBro

@MainActor @Test func everyShortcutKeyIsOnTheCurrentLayout() {
    let codes = Shortcut.allowedKeys.compactMap { Shortcut.layoutKeyCode(for: $0, command: true) }
    #expect(codes.count == Shortcut.allowedKeys.count)
    #expect(Set(codes).count == codes.count)
}
