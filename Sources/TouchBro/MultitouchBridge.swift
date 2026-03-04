import Foundation

typealias MTDeviceRef = UnsafeMutableRawPointer

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerId: Int32
    var handId: Int32
    var normalizedPosition: MTVector
    var total: Float
    var pressure: Float
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolutePosition: MTVector
    var field14: Int32
    var field15: Int32
    var density: Float
}

private typealias MTFrameCallbackFunction = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Void

@_silgen_name("MTDeviceIsAvailable")
private func MTDeviceIsAvailable() -> Bool

@_silgen_name("MTDeviceCreateDefault")
private func MTDeviceCreateDefault() -> MTDeviceRef?

@_silgen_name("MTDeviceStart")
private func MTDeviceStart(_ device: MTDeviceRef?, _ mode: Int32) -> Int32

@_silgen_name("MTDeviceStop")
private func MTDeviceStop(_ device: MTDeviceRef?) -> Int32

@_silgen_name("MTDeviceRelease")
private func MTDeviceRelease(_ device: MTDeviceRef?)

@_silgen_name("MTRegisterContactFrameCallback")
private func MTRegisterContactFrameCallback(_ device: MTDeviceRef?, _ callback: MTFrameCallbackFunction?)

@_silgen_name("MTUnregisterContactFrameCallback")
private func MTUnregisterContactFrameCallback(_ device: MTDeviceRef?, _ callback: MTFrameCallbackFunction?)

final class MultitouchBridge {
    static let shared = MultitouchBridge()

    var onFrame: ((Float, Int32, Int) -> Void)?
    private let callbackQueue = DispatchQueue(label: "touchbro.multitouch.callback", qos: .background)
    private let stateQueue = DispatchQueue(label: "touchbro.multitouch.state", qos: .utility)
    private var captureEnabled = false
    private var lastDispatchTime: Double = 0

    private var device: MTDeviceRef?
    private var isRunning = false

    private init() { }

    func setCaptureEnabled(_ enabled: Bool) {
        stateQueue.async {
            self.captureEnabled = enabled
        }
    }

    func start() {
        stateQueue.async {
            self.startLocked()
        }
    }

    private func startLocked() {
        guard !isRunning else { return }
        guard MTDeviceIsAvailable() else {
            TouchBroDebugLog.write("MT bridge: device unavailable")
            return
        }

        if device == nil {
            device = MTDeviceCreateDefault()
        }

        guard let device else {
            TouchBroDebugLog.write("MT bridge: MTDeviceCreateDefault failed")
            return
        }

        MultitouchCallbackBox.current = self
        MTRegisterContactFrameCallback(device, multitouchFrameCallback)
        let startResult = MTDeviceStart(device, 0)
        isRunning = true
        TouchBroDebugLog.write("MT bridge: started (MTDeviceStart=\(startResult))")
    }

    func stop() {
        stateQueue.async {
            self.stopLocked()
        }
    }

    private func stopLocked() {
        guard isRunning else {
            if let device {
                MTDeviceRelease(device)
                self.device = nil
            }
            return
        }

        if let device {
            MTUnregisterContactFrameCallback(device, multitouchFrameCallback)
            _ = MTDeviceStop(device)
            MTDeviceRelease(device)
        }
        captureEnabled = false
        lastDispatchTime = 0
        MultitouchCallbackBox.current = nil
        device = nil
        isRunning = false
        TouchBroDebugLog.write("MT bridge: stopped")
    }

    fileprivate func onContactFrame(touchesRaw: UnsafeMutableRawPointer?, count: Int32) {
        guard let touchesRaw, count > 0 else { return }

        let shouldProcess: Bool = stateQueue.sync {
            guard captureEnabled else {
                return false
            }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastDispatchTime < 0.03 {
                return false
            }
            lastDispatchTime = now
            return true
        }

        guard shouldProcess else {
            return
        }

        let touches = touchesRaw.bindMemory(to: MTTouch.self, capacity: Int(count))

        var maxPressure: Float = 0
        var maxState: Int32 = 0
        let touchCount = Int(count)

        for index in 0..<touchCount {
            let touch = touches[index]
            if touch.pressure > maxPressure {
                maxPressure = touch.pressure
            }
            if touch.state > maxState {
                maxState = touch.state
            }
        }

        guard maxPressure > 0 else { return }
        callbackQueue.async { [weak self] in
            self?.onFrame?(maxPressure, maxState, touchCount)
        }
    }
}

private enum MultitouchCallbackBox {
    static weak var current: MultitouchBridge?
}

private let multitouchFrameCallback: MTFrameCallbackFunction = { _, touchesRaw, count, _, _ in
    MultitouchCallbackBox.current?.onContactFrame(touchesRaw: touchesRaw, count: count)
}
