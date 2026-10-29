import Testing
@testable import TouchBro

@Test func frameGateFollowsTheTrackpadAFingerLandedOn() {
    var gate = FrameGate()
    let admitted = [
        gate.admit(device: 1, landing: false, at: 1.00),  // finger resting on trackpad 1
        gate.admit(device: 2, landing: true, at: 1.01),   // a finger lands on trackpad 2
        gate.admit(device: 1, landing: false, at: 1.05),  // trackpad 1 is ignored now
        gate.admit(device: 2, landing: false, at: 1.05),
        gate.admit(device: 2, landing: false, at: 1.06),  // under 30 ms since the last frame
    ]
    #expect(admitted == [true, true, false, true, false])
}
