package usb

import "sync"

/// HID class requests (HID 1.11 §7.2).
let hidGetReport: uint8 = 0x01
let hidGetIdle: uint8 = 0x02
let hidGetProtocol: uint8 = 0x03
let hidSetReport: uint8 = 0x09
let hidSetIdle: uint8 = 0x0a
let hidSetProtocol: uint8 = 0x0b

/// Reports a HID device has made and the host hasn't read: what an
/// interrupt IN endpoint answers with, oldest first.
final class ReportQueue {
    let lock = sync.Mutex()
    var reports: [[uint8]] = []

    func Push(_ r: [uint8]) {
        lock.withLock {
            // A host that stopped polling shouldn't make us hold every key.
            if reports.count >= 64 { reports.removeFirst() }
            reports.append(r)
        }
    }

    func Pop() -> Transfer {
        lock.withLock { reports.isEmpty ? Transfer.nak : Transfer.data(reports.removeFirst()) }
    }

    func Clear() {
        lock.withLock { reports.removeAll() }
    }
}

/// HID requests every HID device answers alike: its report descriptor,
/// idle rate and protocol.
func hidControl(_ setup: Setup, report: [uint8], hid: [uint8], current: [uint8]) -> Transfer {
    if setup.Kind == 0 && setup.Request == 0x06 {
        switch setup.Value >> 8 {
        case 0x21: return .data(hid)                    // HID descriptor
        case 0x22: return .data(report)                 // report descriptor
        default: return .stall
        }
    }
    if setup.Kind == 1 {
        switch setup.Request {
        case hidGetReport: return .data(current)
        case hidGetIdle: return .data([0])
        case hidGetProtocol: return .data([1])          // report protocol
        case hidSetReport, hidSetIdle, hidSetProtocol: return .data([])
        default: return .stall
        }
    }
    if setup.Kind == 0 {
        return .data([])                                // SET_INTERFACE, CLEAR_FEATURE …
    }
    return .stall
}

/// A HID boot keyboard (8-byte reports: modifiers, reserved, six keys).
public final class Keyboard: Peripheral {
    let queue = ReportQueue()
    let lock = sync.Mutex()
    var modifiers: uint8 = 0
    var held: [uint8] = []
    public var OnData: (() -> Void)? = nil

    public init() {}

    public var Speed: uint8 { 1 }
    public var Product: string { "Vertex Keyboard" }
    public var DeviceDescriptor: [uint8] { deviceDescriptor(vendor: vendorId, product: 0x0001) }

    var hidDescriptor: [uint8] {
        [9, 0x21, 0x11, 0x01, 0, 1, 0x22, uint8(Keyboard.reportDescriptor.count), 0]
    }

    public var ConfigurationDescriptor: [uint8] {
        var d: [uint8] = [9, 2, 34, 0, 1, 1, 0, 0xa0, 50,              // configuration
                          9, 4, 0, 0, 1, 3, 1, 1, 0]                    // interface: HID, boot, keyboard
        d.append(contentsOf: hidDescriptor)
        d.append(contentsOf: [7, 5, 0x81, 3, 8, 0, 10])                // endpoint 1 IN, interrupt, 10 ms
        return d
    }

    /// The standard boot-keyboard report descriptor (HID 1.11 appendix B.1).
    static let reportDescriptor: [uint8] = [
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
        0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xc0,
    ]

    func report() -> [uint8] {
        var r: [uint8] = [modifiers, 0]
        r.append(contentsOf: held.prefix(6))
        while r.count < 8 { r.append(0) }
        return r
    }

    /// A key went down or up, by HID usage (page 7): 0x04 is A, 0x28
    /// Enter, 0xe0...0xe7 the modifiers.
    public func Key(_ usage: uint8, pressed: bool) {
        let r = lock.withLock { () -> [uint8] in
            if usage >= 0xe0 && usage <= 0xe7 {
                let bit = uint8(1) << (usage - 0xe0)
                if pressed { modifiers |= bit } else { modifiers &= ~bit }
            } else if pressed {
                if !held.contains(usage) { held.append(usage) }
            } else {
                held.removeAll(where: { $0 == usage })
            }
            return report()
        }
        queue.Push(r)
        OnData?()
    }

    /// Queues a report as is: the modifier byte and up to six usages held.
    public func Press(modifiers: uint8, keys: [uint8]) {
        var r: [uint8] = [modifiers, 0]
        r.append(contentsOf: keys.prefix(6))
        while r.count < 8 { r.append(0) }
        queue.Push(r)
        OnData?()
    }

    public func Control(_ setup: Setup, _ data: [uint8]) -> Transfer {
        let current = lock.withLock { report() }
        return hidControl(setup, report: Keyboard.reportDescriptor, hid: hidDescriptor, current: current)
    }

    public func In(endpoint: uint8, max: int) async -> Transfer {
        queue.Pop()
    }

    public func Out(endpoint: uint8, _ data: [uint8]) async -> Transfer { .stall }

    public func Reset() {
        queue.Clear()
    }
}

/// A HID tablet: an absolute pointer, so the guest cursor sits exactly
/// where the host's is and nothing has to be captured. Reports: buttons,
/// x and y in 0...32767, wheel.
public final class Tablet: Peripheral {
    let queue = ReportQueue()
    let lock = sync.Mutex()
    var x: uint16 = 0
    var y: uint16 = 0
    var buttons: uint8 = 0
    public var OnData: (() -> Void)? = nil

    public init() {}

    public var Speed: uint8 { 1 }
    public var Product: string { "Vertex Tablet" }
    public var DeviceDescriptor: [uint8] { deviceDescriptor(vendor: vendorId, product: 0x0002) }

    var hidDescriptor: [uint8] {
        [9, 0x21, 0x11, 0x01, 0, 1, 0x22, uint8(Tablet.reportDescriptor.count), 0]
    }

    public var ConfigurationDescriptor: [uint8] {
        var d: [uint8] = [9, 2, 34, 0, 1, 1, 0, 0xa0, 50,
                          9, 4, 0, 0, 1, 3, 0, 0, 0]                    // HID, no boot protocol
        d.append(contentsOf: hidDescriptor)
        d.append(contentsOf: [7, 5, 0x81, 3, 6, 0, 10])
        return d
    }

    static let reportDescriptor: [uint8] = [
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xff, 0x7f, 0x35, 0x00, 0x46, 0xff, 0x7f,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x35, 0x00, 0x45, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xc0, 0xc0,
    ]

    func report(wheel: int8) -> [uint8] {
        [buttons, uint8(x & 0xff), uint8(x >> 8), uint8(y & 0xff), uint8(y >> 8), uint8(bitPattern: wheel)]
    }

    /// Moves the pointer. `x` and `y` are fractions of the screen, 0...1.
    public func Move(x: float64, y: float64) {
        let r = lock.withLock { () -> [uint8] in
            self.x = uint16(max(0, min(1, x)) * 32767)
            self.y = uint16(max(0, min(1, y)) * 32767)
            return report(wheel: 0)
        }
        queue.Push(r)
        OnData?()
    }

    /// A button went down or up: 0 primary, 1 secondary, 2 middle.
    public func Button(_ index: int, pressed: bool) {
        if index < 0 || index > 2 { return }
        let r = lock.withLock { () -> [uint8] in
            let bit = uint8(1) << uint8(index)
            if pressed { buttons |= bit } else { buttons &= ~bit }
            return report(wheel: 0)
        }
        queue.Push(r)
        OnData?()
    }

    /// Scrolls the wheel by `clicks` (positive is away from the user).
    public func Wheel(_ clicks: int8) {
        let r: [uint8] = lock.withLock { report(wheel: clicks) }
        queue.Push(r)
        OnData?()
    }

    public func Control(_ setup: Setup, _ data: [uint8]) -> Transfer {
        let current = lock.withLock { report(wheel: 0) }
        return hidControl(setup, report: Tablet.reportDescriptor, hid: hidDescriptor, current: current)
    }

    public func In(endpoint: uint8, max: int) async -> Transfer {
        queue.Pop()
    }

    public func Out(endpoint: uint8, _ data: [uint8]) async -> Transfer { .stall }

    public func Reset() {
        queue.Clear()
    }
}
