package usb

import "sync"

/// A HID boot keyboard (8-byte reports: modifiers, reserved, six keys).
public final class Keyboard: Device {
    let lock = sync.Mutex()
    var reports: [[uint8]] = []

    public init() {}

    public var Speed: uint8 { 1 }
    public var DeviceDescriptor: [uint8] { deviceDescriptor(vendor: vendorId, product: 0x0001) }

    public var ConfigurationDescriptor: [uint8] {
        let report = Keyboard.reportDescriptor
        return [9, 2, 34, 0, 1, 1, 0, 0xa0, 50,                         // configuration
                9, 4, 0, 0, 1, 3, 1, 1, 0,                              // interface: HID, boot, keyboard
                9, 0x21, 0x11, 0x01, 0, 1, 0x22, uint8(report.count), 0, // HID descriptor
                7, 5, 0x81, 3, 8, 0, 10]                                // endpoint 1 IN, interrupt, 10 ms
    }

    /// The standard boot-keyboard report descriptor (HID 1.11 appendix B.1).
    static let reportDescriptor: [uint8] = [
        0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
        0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xc0,
    ]

    /// Queues a report: the modifier byte and up to six HID usage codes held.
    public func Press(modifiers: uint8, keys: [uint8]) {
        var r: [uint8] = [modifiers, 0]
        r.append(contentsOf: keys.prefix(6))
        while r.count < 8 { r.append(0) }
        lock.withLock { reports.append(r) }
    }

    public func Control(_ setup: Setup, _ data: [uint8]) -> Transfer {
        if setup.Request == 0x06 && setup.Value >> 8 == 0x22 {
            return .data(Keyboard.reportDescriptor)                     // GET_DESCRIPTOR(report)
        }
        return .data([])                                                // SET_IDLE, SET_PROTOCOL, SET_REPORT (LEDs)
    }

    public func In(endpoint: uint8, max: int) async -> Transfer {
        lock.withLock { reports.isEmpty ? .nak : .data(reports.removeFirst()) }
    }

    public func Out(endpoint: uint8, _ data: [uint8]) async -> Transfer { .stall }
}

/// A HID tablet: an absolute pointer, so the guest cursor sits exactly
/// where the host's is and nothing has to be captured. Reports: buttons,
/// x and y in 0...32767, wheel.
public final class Tablet: Device {
    let lock = sync.Mutex()
    var reports: [[uint8]] = []

    public init() {}

    public var Speed: uint8 { 1 }
    public var DeviceDescriptor: [uint8] { deviceDescriptor(vendor: vendorId, product: 0x0002) }

    public var ConfigurationDescriptor: [uint8] {
        let report = Tablet.reportDescriptor
        return [9, 2, 34, 0, 1, 1, 0, 0xa0, 50,
                9, 4, 0, 0, 1, 3, 0, 0, 0,                              // HID, no boot protocol
                9, 0x21, 0x11, 0x01, 0, 1, 0x22, uint8(report.count), 0,
                7, 5, 0x81, 3, 6, 0, 10]
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

    /// Moves the pointer. `x` and `y` are fractions of the screen, 0...1.
    public func Move(x: float64, y: float64, buttons: uint8 = 0, wheel: int8 = 0) {
        let ax = uint16(max(0, min(1, x)) * 32767)
        let ay = uint16(max(0, min(1, y)) * 32767)
        let r: [uint8] = [buttons, uint8(ax & 0xff), uint8(ax >> 8), uint8(ay & 0xff), uint8(ay >> 8), uint8(bitPattern: wheel)]
        lock.withLock { reports.append(r) }
    }

    public func Control(_ setup: Setup, _ data: [uint8]) -> Transfer {
        if setup.Request == 0x06 && setup.Value >> 8 == 0x22 {
            return .data(Tablet.reportDescriptor)
        }
        return .data([])
    }

    public func In(endpoint: uint8, max: int) async -> Transfer {
        lock.withLock { reports.isEmpty ? .nak : .data(reports.removeFirst()) }
    }

    public func Out(endpoint: uint8, _ data: [uint8]) async -> Transfer { .stall }
}
