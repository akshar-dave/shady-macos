import AppKit

// MARK: - Trackpad

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias MTContactCallback = @convention(c)
    (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
typealias MTRegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
typealias MTDeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Void
typealias MTDeviceStopFn = @convention(c) (MTDeviceRef, Int32) -> Void
typealias MTUnregisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void


/// Raw finger positions, read straight from the multitouch device.
///
/// AppKit's touch data (`NSTouch` on gesture events) turned out to be far too sparse to build a
/// gesture on: one touch-down recorded in forty seconds of deliberate swiping, because the
/// NSEvent global monitors that carry it fire only intermittently. MultitouchSupport reports
/// every finger on every frame, roughly 120 times a second, which is what this needs.
///
/// This is a private framework. It is stable and has been used by trackpad utilities for many
/// years, but it is not API: if a macOS release breaks it, `available` goes false and the
/// gesture falls back to AppKit's touch data.
final class Trackpad {
    static let shared = Trackpad()

    struct MTPoint { var x: Float = 0; var y: Float = 0 }
    struct MTVector { var position = MTPoint(); var velocity = MTPoint() }

    /// Layout must match the framework's `MTTouch` exactly.
    struct MTTouch {
        var frame: Int32 = 0
        var timestamp: Double = 0
        var identifier: Int32 = 0
        var state: Int32 = 0
        var fingerId: Int32 = 0
        var handId: Int32 = 0
        var normalized = MTVector()
        var zTotal: Float = 0
        var field9: Int32 = 0
        var angle: Float = 0
        var majorAxis: Float = 0
        var minorAxis: Float = 0
        var absolute = MTVector()
        var field14: Int32 = 0
        var field15: Int32 = 0
        var zDensity: Float = 0
    }

    private(set) var available = false

    private let lock = NSLock()
    /// Called on the main thread for every multitouch frame.
    var onFrame: ((_ fingers: Int, _ y: CGFloat, _ time: TimeInterval) -> Void)?

    /// One smoothing filter per finger, keyed by the contact's identifier.
    ///
    /// Smoothing the *mean* of the fingers, which is what this used to do, filters the wrong
    /// signal. Fidgeting with the shade rolls the fingers rather than sliding them, and a rolling
    /// finger's contact patch - which is what `normalized.position` reports - travels further
    /// than the finger itself does. That roll noise is largely uncorrelated between the two
    /// fingers, so filtering each one before averaging removes it twice: once by the filter, and
    /// again by the averaging. Filtering afterwards gets only the second.
    ///
    /// Touched only from the multitouch callback thread, which is why it sits outside `lock`.
    private var fingerFilters: [Int32: OneEuroFilter] = [:]

    fileprivate func update(raw: UnsafeMutableRawPointer?, count: Int32) {
        let n = Int(count)
        let now = CACurrentMediaTime()

        // The mean, not the maximum: when one finger of a pair lifts, the maximum jumps to the
        // remaining finger and reads as a sudden movement that never happened.
        var top: CGFloat = 0
        if let raw, n > 0 {
            let touches = raw.assumingMemoryBound(to: MTTouch.self)
            var present = Set<Int32>()
            var sum: CGFloat = 0
            for i in 0..<n {
                let id = touches[i].identifier
                present.insert(id)
                var f = fingerFilters[id] ?? OneEuroFilter(minCutoff: Config.smoothingMinCutoff,
                                                           beta: Config.smoothingBeta)
                sum += CGFloat(f.filter(Double(touches[i].normalized.position.y), at: now))
                fingerFilters[id] = f
            }
            top = sum / CGFloat(n)
            // Discard filters for fingers that have left, so a recycled identifier starts clean
            // rather than resuming some earlier finger's history.
            if fingerFilters.count != present.count {
                for id in Array(fingerFilters.keys) where !present.contains(id) {
                    fingerFilters.removeValue(forKey: id)
                }
            }
        } else {
            fingerFilters.removeAll()
        }

        lock.lock()
        lastFrameAt = now
        healedWhileQuiet = false
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.onFrame?(n, top, now) }
    }

    /// The device list, held for as long as its devices are in use.
    ///
    /// This must outlive `devices`, which are raw pointers *into* it. `MTDeviceCreateList` returns
    /// an owned CFArray that retains the device objects; letting it go releases them, and the
    /// pointers below become dangling. An earlier version did exactly that - took the list with
    /// `takeRetainedValue()`, kept the pointers, and let the array fall out of scope at the end of
    /// `start()`. Nothing went wrong until `restart()` called `MTDeviceStop` on those addresses,
    /// which corrupted the heap and aborted the process on the next allocation.
    private var deviceList: CFMutableArray?
    private var devices: [MTDeviceRef] = []
    private var stopDevice: MTDeviceStopFn?
    private var unregister: MTUnregisterFn?
    private var lastRestartAt: CFTimeInterval = 0
    /// When the last frame arrived. Used to notice that the device has gone quiet.
    private var lastFrameAt: CFTimeInterval = 0

    func start() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_LAZY) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            DebugLog.write("MultitouchSupport unavailable: \(reason)")
            return
        }
        guard let pCreate = dlsym(lib, "MTDeviceCreateList"),
              let pRegister = dlsym(lib, "MTRegisterContactFrameCallback"),
              let pStart = dlsym(lib, "MTDeviceStart") else {
            DebugLog.write("MultitouchSupport symbols missing")
            return
        }

        let createList = unsafeBitCast(pCreate, to: MTDeviceCreateListFn.self)
        let register = unsafeBitCast(pRegister, to: MTRegisterFn.self)
        let startDevice = unsafeBitCast(pStart, to: MTDeviceStartFn.self)
        if let pStop = dlsym(lib, "MTDeviceStop") {
            stopDevice = unsafeBitCast(pStop, to: MTDeviceStopFn.self)
        }
        if let pUnregister = dlsym(lib, "MTUnregisterContactFrameCallback") {
            unregister = unsafeBitCast(pUnregister, to: MTUnregisterFn.self)
        }

        guard let list = createList()?.takeRetainedValue() else {
            DebugLog.write("no multitouch devices")
            return
        }
        // Held for the lifetime of the pointers taken from it.
        deviceList = list
        let count = CFArrayGetCount(list)
        devices.removeAll()
        for i in 0..<count {
            guard let device = CFArrayGetValueAtIndex(list, i) else { continue }
            let ref = UnsafeMutableRawPointer(mutating: device)
            register(ref, trackpadContactCallback)
            startDevice(ref, 0)
            devices.append(ref)
        }
        available = count > 0
        lastFrameAt = CACurrentMediaTime()
        DebugLog.write("multitouch devices started: \(count)")
    }

    /// Stop and re-register every device.
    ///
    /// The multitouch device stops delivering frames across a sleep/wake cycle: the registration
    /// is made against a device that does not survive the transition, and nothing tells us - the
    /// callback simply never fires again, so the gesture is silently dead until the app is
    /// relaunched. Re-registering on wake is the fix.
    func restart(reason: String) {
        // Wake, screens-wake and unlock all arrive within milliseconds of each other, and tearing
        // the devices down three times in a row is both pointless and the riskiest thing this
        // code does.
        let now = CACurrentMediaTime()
        guard now - lastRestartAt > 2 else {
            DebugLog.write("multitouch restart (\(reason)) skipped; one just happened")
            return
        }
        lastRestartAt = now
        DebugLog.write("multitouch restart (\(reason)); had \(devices.count) device(s)")

        // Order matters: the callback is removed, then the device stopped, and only then is the
        // list released - each device stays alive until the last thing that touches it is done.
        for d in devices {
            unregister?(d, trackpadContactCallback)
            stopDevice?(d, 0)
        }
        devices.removeAll()
        deviceList = nil
        available = false
        start()
        DebugLog.write("multitouch restart done; \(devices.count) device(s)")
    }

    /// Set once the device has been re-registered for the current quiet spell, so a machine left
    /// alone for an hour re-registers once rather than every few seconds.
    private var healedWhileQuiet = false

    /// Re-register if the device has gone silent for longer than `threshold`.
    ///
    /// A backstop, not a diagnosis. The registration has now been lost across sleep, across screen
    /// lock, and each time for reasons that had to be found by hand; enumerating the transitions
    /// one at a time has been wrong twice. Silence is the one symptom common to all of them and it
    /// is directly observable, so it is what this acts on. Re-registering an idle device costs
    /// nothing and is invisible, which is what makes it safe to do speculatively.
    ///
    /// Frames arrive only when fingers are on the pad, so silence is the normal state of an
    /// untouched Mac. That is fine: the worst case is one needless re-registration per quiet
    /// spell, and the best case is that the gesture is already working again by the time anyone
    /// reaches for the trackpad.
    func healIfQuiet(threshold: CFTimeInterval) {
        lock.lock()
        let quiet = CACurrentMediaTime() - lastFrameAt
        let alreadyHealed = healedWhileQuiet
        lock.unlock()
        guard available, quiet > threshold, !alreadyHealed else { return }
        lock.lock(); healedWhileQuiet = true; lock.unlock()
        restart(reason: String(format: "no frames for %.0fs", quiet))
    }
}

/// C callback; must be a plain function, so it forwards into the singleton.
private func trackpadContactCallback(device: Int32,
                                     touches: UnsafeMutableRawPointer?,
                                     count: Int32,
                                     timestamp: Double,
                                     frame: Int32) -> Int32 {
    Trackpad.shared.update(raw: touches, count: count)
    return 0
}
