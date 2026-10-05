package virtio

import (
    "encoding/binary"
    "sync"
    "vm/device"
)

/// virtio-input (spec §5.8): evdev events, for Linux guests with a
/// display, and Android 10+'s touchscreen. Windows has no inbox driver, so
/// Windows gets usb.Keyboard and usb.Tablet instead. Queues: event 0, status 1.
public final class Input: Device, device.TouchScreen {
    /// A keyboard; a tablet (absolute pointer, 0–32767); or a touchscreen
    /// with keys, in screen pixels, as Android reads one.
    public enum Kind { case keyboard, tablet, touchscreen }

    public let Id = DeviceId.input
    public let DeviceKind: Kind
    /// The touchscreen's name, which picks the guest's input config (Android's
    /// /vendor/usr/idc/<name>.idc), and its size in pixels.
    public let Name: string
    public let Width: int
    public let Height: int
    var touching = false
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil
    let lock = sync.Mutex()

    var select: uint8 = 0
    var subsel: uint8 = 0
    var configSize: uint8 = 0
    var configPayload: [uint8] = [uint8](repeating: 0, count: 128)

    public init(_ kind: Kind) {
        DeviceKind = kind
        Name = kind == .tablet ? "Vertex VirtIO Tablet" : "Vertex VirtIO Keyboard"
        Width = 0
        Height = 0
    }

    /// A touchscreen `width` × `height` pixels that also has keys (KEY_ESC
    /// to KEY_MICMUTE), called `name`: Android 10's emulator calls its
    /// "virtio_input_multi_touch_1", which its idc makes a touchscreen.
    public init(touchscreen name: string, width: int, height: int) {
        DeviceKind = .touchscreen
        Name = name
        Width = width
        Height = height
    }

    public var Features: uint64 { CommonFeatures }
    public var QueueSizes: [uint16] { [64, 64] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            if offset == 0 {
                var val: uint64 = uint64(select)
                if size >= 2 { val |= uint64(subsel) << 8 }
                if size >= 4 { val |= uint64(configSize) << 16 }
                return val
            }
            if offset == 1 {
                var val: uint64 = uint64(subsel)
                if size >= 2 { val |= uint64(configSize) << 8 }
                return val
            }
            if offset == 2 {
                return uint64(configSize)
            }
            if offset >= 8 {
                let idx = int(offset - 8)
                var res: uint64 = 0
                for b in 0..<int(size) {
                    let p = idx + b
                    if p < configPayload.count {
                        res |= uint64(configPayload[p]) << (b * 8)
                    }
                }
                return res
            }
            return 0
        }
    }

    public func WriteConfig(offset: uint64, size: uint8, value: uint64) {
        lock.withLock {
            if offset == 0 {
                select = uint8(value & 0xff)
                if size >= 2 {
                    subsel = uint8((value >> 8) & 0xff)
                }
                recomputeConfig()
            } else if offset == 1 {
                subsel = uint8(value & 0xff)
                recomputeConfig()
            }
        }
    }

    func recomputeConfig() {
        var bytes = [uint8](repeating: 0, count: 128)
        var sz: uint8 = 0

        switch select {
        case 0x01: // VIRTIO_INPUT_CFG_ID_NAME
            let utf8 = [uint8](Name.utf8)
            sz = uint8(min(128, utf8.count))
            for i in 0..<int(sz) { bytes[i] = utf8[i] }

        case 0x02: // VIRTIO_INPUT_CFG_ID_SERIAL
            let serial = DeviceKind == .tablet ? "vertex-tablet-0" : DeviceKind == .touchscreen ? "vertex-touchscreen-0" : "vertex-keyboard-0"
            let utf8 = [uint8](serial.utf8)
            sz = uint8(min(128, utf8.count))
            for i in 0..<int(sz) { bytes[i] = utf8[i] }

        case 0x03: // VIRTIO_INPUT_CFG_ID_DEVIDS
            binary.LittleEndian.PutUint16(&bytes, 0x0006, at: 0) // BUS_VIRTUAL
            binary.LittleEndian.PutUint16(&bytes, 0x1af4, at: 2) // Red Hat / VirtIO
            binary.LittleEndian.PutUint16(&bytes, DeviceKind == .tablet ? 0x0002 : DeviceKind == .touchscreen ? 0x0003 : 0x0001, at: 4)
            binary.LittleEndian.PutUint16(&bytes, 0x0001, at: 6)
            sz = 8

        case 0x10: // VIRTIO_INPUT_CFG_PROP_BITS
            if DeviceKind != .keyboard {
                bytes[0] = 0x02 // INPUT_PROP_DIRECT
                sz = 1
            } else {
                sz = 0
            }

        case 0x11: // VIRTIO_INPUT_CFG_EV_BITS
            switch subsel {
            case 0x00: // EV_SYN
                bytes[0] = 0x01 // SYN_REPORT
                sz = 1
            case 0x01: // EV_KEY
                if DeviceKind == .touchscreen {
                    // KEY_ESC..KEY_MICMUTE (1..248), and BTN_TOUCH (330).
                    for k in 1...248 { bytes[k / 8] |= uint8(1 << (k % 8)) }
                    bytes[41] = 0x04
                    sz = 42
                } else if DeviceKind == .tablet {
                    // BTN_LEFT (272), BTN_RIGHT (273), BTN_MIDDLE (274) -> byte 34
                    bytes[34] = 0x07
                    // BTN_TOUCH (330) -> byte 41, bit 2
                    bytes[41] = 0x04
                    sz = 42
                } else {
                    for k in 1...255 {
                        bytes[k / 8] |= uint8(1 << (k % 8))
                    }
                    sz = 32
                }
            case 0x03: // EV_ABS
                if DeviceKind != .keyboard {
                    // ABS_X (0), ABS_Y (1) -> bit 0, 1 -> 0x03
                    bytes[0] = 0x03
                    sz = 1
                } else {
                    sz = 0
                }
            default:
                sz = 0
            }

        case 0x12: // VIRTIO_INPUT_CFG_ABS_INFO
            if DeviceKind != .keyboard && (subsel == 0 || subsel == 1) {
                // min = 0, max = 32767 (a touchscreen: its pixels)
                let maxValue = DeviceKind == .touchscreen ? (subsel == 0 ? Width : Height) - 1 : 32767
                binary.LittleEndian.PutUint32(&bytes, 0, at: 0)
                binary.LittleEndian.PutUint32(&bytes, uint32(maxValue), at: 4)
                binary.LittleEndian.PutUint32(&bytes, 0, at: 8)
                binary.LittleEndian.PutUint32(&bytes, 0, at: 12)
                binary.LittleEndian.PutUint32(&bytes, 0, at: 16)
                sz = 20
            } else {
                sz = 0
            }

        default:
            sz = 0
        }

        configPayload = bytes
        configSize = sz
    }

    public func Activate(queues: [Queue], features: uint64, notify: any Notifier) throws {
        self.queues = queues
        self.notify = notify
    }

    public func Reset() {
        queues = []
        notify = nil
    }

    public func Notified(queue index: int) {}

    /// Queues one evdev event (type, code, value) for the guest.
    public func Send(type: uint16, code: uint16, value: uint32) {
        guard !queues.isEmpty, let chain = try? queues[0].Pop() else { return }
        var ev = [uint8](repeating: 0, count: 8)
        binary.LittleEndian.PutUint16(&ev, type, at: 0)
        binary.LittleEndian.PutUint16(&ev, code, at: 2)
        binary.LittleEndian.PutUint32(&ev, value, at: 4)
        if let n = try? queues[0].WriteAll(chain, ev), (try? queues[0].Push(chain.Head, written: n)) == true {
            notify?.QueueUsed(0)
        }
    }

    /// Sends an absolute position event (0..32767 for tablet).
    public func MoveAbsolute(x: int32, y: int32) {
        let clX = uint32(max(0, min(32767, x)))
        let clY = uint32(max(0, min(32767, y)))
        Send(type: 3 /* EV_ABS */, code: 0 /* ABS_X */, value: clX)
        Send(type: 3 /* EV_ABS */, code: 1 /* ABS_Y */, value: clY)
        Send(type: 0 /* EV_SYN */, code: 0 /* SYN_REPORT */, value: 0)
    }

    /// Sends a button press or release.
    /// button: 0 (primary/left), 1 (secondary/right), 2 (middle)
    public func Button(button: int32, pressed: bool) {
        var code: uint16 = 0x110 // BTN_LEFT
        if button == 1 { code = 0x111 } // BTN_RIGHT
        else if button == 2 { code = 0x112 } // BTN_MIDDLE
        Send(type: 1 /* EV_KEY */, code: code, value: pressed ? 1 : 0)
        if button == 0 {
            Send(type: 1 /* EV_KEY */, code: 0x14a /* BTN_TOUCH */, value: pressed ? 1 : 0)
        }
        Send(type: 0 /* EV_SYN */, code: 0 /* SYN_REPORT */, value: 0)
    }

    /// Sends a keyboard key press or release event for Linux evdev.
    public func Key(code: uint16, pressed: bool) {
        Send(type: 1 /* EV_KEY */, code: code, value: pressed ? 1 : 0)
        Send(type: 0 /* EV_SYN */, code: 0 /* SYN_REPORT */, value: 0)
    }

    /// A key on the touchscreen (device.TouchScreen).
    public func Key(_ code: uint16, pressed: bool) {
        Key(code: code, pressed: pressed)
    }

    /// A finger at (x, y) in the touchscreen's pixels: down, moving, or lifted.
    public func Touch(x: int, y: int, down: bool) {
        let was = lock.withLock { touching }
        if !down && !was { return }
        Send(type: 3 /* EV_ABS */, code: 0 /* ABS_X */, value: uint32(max(0, min(x, Width - 1))))
        Send(type: 3 /* EV_ABS */, code: 1 /* ABS_Y */, value: uint32(max(0, min(y, Height - 1))))
        if down != was {
            Send(type: 1 /* EV_KEY */, code: 0x14a /* BTN_TOUCH */, value: down ? 1 : 0)
            lock.withLock { touching = down }
        }
        Send(type: 0 /* EV_SYN */, code: 0 /* SYN_REPORT */, value: 0)
    }

    public var Touching: bool { lock.withLock { touching } }
}
