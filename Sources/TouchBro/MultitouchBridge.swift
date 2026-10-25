import AppKit
import IOKit

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

@_silgen_name("MTDeviceCreateList")
private func MTDeviceCreateList() -> Unmanaged<CFArray>?

@_silgen_name("MTDeviceStart")
private func MTDeviceStart(_ device: MTDeviceRef?, _ mode: Int32) -> Int32

@_silgen_name("MTDeviceStop")
private func MTDeviceStop(_ device: MTDeviceRef?) -> Int32

@_silgen_name("MTRegisterContactFrameCallback")
private func MTRegisterContactFrameCallback(_ device: MTDeviceRef?, _ callback: MTFrameCallbackFunction?)

@_silgen_name("MTUnregisterContactFrameCallback")
private func MTUnregisterContactFrameCallback(_ device: MTDeviceRef?, _ callback: MTFrameCallbackFunction?)

final class MultitouchBridge {
    static let shared = MultitouchBridge()

    /// (max pressure, max touch state, touch count, a finger is landing)
    var onFrame: ((Float, Int32, Int, Bool) -> Void)?
    private let callbackQueue = DispatchQueue(label: "touchbro.multitouch.callback", qos: .background)
    private let stateQueue = DispatchQueue(label: "touchbro.multitouch.state", qos: .utility)
    private var captureEnabled = false
    private var lastDispatchTime: Double = 0

    // The list owns the devices; keeping it alive keeps every device ref valid.
    private var deviceList: CFArray?
    private var devices: [MTDeviceRef] = []
    private var isRunning = false
    // Set by start()/stop(): lets wake and device-added events start a bridge that found no device yet.
    private var wantsRunning = false
    private var deviceNotifyPort: IONotificationPortRef?
    private var deviceAddedIterator: io_iterator_t = 0

    private init() {
        watchForDeviceChanges()
    }

    func setCaptureEnabled(_ enabled: Bool) {
        stateQueue.async {
            self.captureEnabled = enabled
        }
    }

    func start() {
        stateQueue.async {
            self.wantsRunning = true
            self.startLocked()
        }
    }

    private func startLocked() {
        guard !isRunning else { return }
        guard MTDeviceIsAvailable(), let list = MTDeviceCreateList()?.takeRetainedValue() else {
            TouchBroDebugLog.write("MT bridge: device unavailable")
            return
        }

        deviceList = list
        devices = (list as [AnyObject]).map { Unmanaged.passUnretained($0).toOpaque() }
        MultitouchCallbackBox.current = self
        for device in devices {
            MTRegisterContactFrameCallback(device, multitouchFrameCallback)
            _ = MTDeviceStart(device, 0)
        }
        isRunning = true
        TouchBroDebugLog.write("MT bridge: started (devices=\(devices.count))")
    }

    func stop() {
        stateQueue.async {
            self.wantsRunning = false
            self.stopLocked()
        }
    }

    private func stopLocked() {
        guard isRunning else { return }

        for device in devices {
            MTUnregisterContactFrameCallback(device, multitouchFrameCallback)
            _ = MTDeviceStop(device)
        }
        captureEnabled = false
        lastDispatchTime = 0
        MultitouchCallbackBox.current = nil
        devices = []
        deviceList = nil
        isRunning = false
        TouchBroDebugLog.write("MT bridge: stopped")
    }

    /// Device refs go stale after sleep, and a trackpad connected later is not in the list.
    private func watchForDeviceChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stateQueue.async { self?.scheduleRestartLocked(reason: "wake") }
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        deviceNotifyPort = port
        IONotificationPortSetDispatchQueue(port, stateQueue)

        let deviceAdded: IOServiceMatchingCallback = { refcon, iterator in
            drainIterator(iterator)
            guard let refcon else { return }
            Unmanaged<MultitouchBridge>.fromOpaque(refcon).takeUnretainedValue()
                .scheduleRestartLocked(reason: "device added")
        }
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            deviceAdded,
            Unmanaged.passUnretained(self).toOpaque(),
            &deviceAddedIterator
        )
        // Draining arms the notification; devices present now are picked up by start().
        drainIterator(deviceAddedIterator)
    }

    private func scheduleRestartLocked(reason: String) {
        guard wantsRunning else { return }
        // A device needs a moment after wake or connect before it delivers frames.
        stateQueue.asyncAfter(deadline: .now() + 1.0) {
            guard self.wantsRunning else { return }
            let capture = self.captureEnabled
            self.stopLocked()
            self.startLocked()
            self.captureEnabled = capture
            TouchBroDebugLog.write("MT bridge: restarted (\(reason))")
        }
    }

    fileprivate func onContactFrame(touchesRaw: UnsafeMutableRawPointer?, count: Int32) {
        guard let touchesRaw, count > 0 else { return }

        let touches = touchesRaw.bindMemory(to: MTTouch.self, capacity: Int(count))

        var maxPressure: Float = 0
        var maxState: Int32 = 0
        var landing = false
        let touchCount = Int(count)

        for index in 0..<touchCount {
            let touch = touches[index]
            if touch.pressure > maxPressure {
                maxPressure = touch.pressure
            }
            if touch.state > maxState {
                maxState = touch.state
            }
            // States 1-3: the finger is approaching or just made contact.
            if (1...3).contains(touch.state) {
                landing = true
            }
        }

        guard maxPressure > 0 || landing else { return }

        let shouldProcess: Bool = stateQueue.sync {
            guard captureEnabled else {
                return false
            }

            // Landing frames are short-lived, so they skip the throttle.
            let now = CFAbsoluteTimeGetCurrent()
            if !landing && now - lastDispatchTime < 0.03 {
                return false
            }
            lastDispatchTime = now
            return true
        }

        guard shouldProcess else {
            return
        }

        callbackQueue.async { [weak self] in
            self?.onFrame?(maxPressure, maxState, touchCount, landing)
        }
    }
}

private func drainIterator(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 {
        IOObjectRelease(service)
    }
}

private enum MultitouchCallbackBox {
    static weak var current: MultitouchBridge?
}

private let multitouchFrameCallback: MTFrameCallbackFunction = { _, touchesRaw, count, _, _ in
    MultitouchCallbackBox.current?.onContactFrame(touchesRaw: touchesRaw, count: count)
}
