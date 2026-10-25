import Testing
@testable import TouchBro

/// Pressure curves recorded on a Force Touch trackpad (macOS 27), starting at the click,
/// one frame every 30 ms like MultitouchBridge delivers them.
private func fires(_ curve: [Float]) -> Bool {
    var detector = ForcePressDetector()
    detector.begin(at: 0)
    var fired = false
    for (index, pressure) in curve.enumerated() {
        fired = detector.feed(pressure: pressure, at: Double(index) * 0.03) || fired
    }
    return fired
}

@Test func normalClicksDoNotFire() {
    #expect(!fires([123, 137, 201, 255, 256, 256, 208, 54]))
    #expect(!fires([134, 197, 248, 256, 216, 88, 50]))
    #expect(!fires([123, 135, 182, 221, 231, 118, 50]))
}

@Test func hardPressesFire() {
    #expect(fires([136, 212, 335, 378, 478, 615, 701, 577]))
    #expect(fires([120, 131, 257, 342, 462, 509, 555, 578]))
}

@Test func lightTouchNeedsAbsoluteRise() {
    // Ratio far above 1.9, but a rise under 170 is still a light touch.
    #expect(!fires([10, 12, 40, 90, 120]))
}
