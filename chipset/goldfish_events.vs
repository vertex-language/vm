package chipset

import (
    "sync"
    "vm/device"
)

/// The Android emulator's input device ("generic,goldfish-events-keypad"):
/// a queue of evdev events the guest reads one word at a time, and a
/// description of what it can report, read page by page. Goldfish kernels
/// before 4.x drive it as their only input. It is called "qwerty2", so
/// Android's /system/usr/idc/qwerty2.idc makes it a touchscreen and a
/// keyboard, as on the emulator.
public final class GoldfishEvents: device.Mmio {
    public static let Size: uint64 = 0x1000

    // Registers (drivers/input/keyboard/goldfish_events.c).
    static let regRead: uint64 = 0x00      // read: the next word of the next event
    static let regSetPage: uint64 = 0x00   // write: what REG_LEN and REG_DATA describe
    static let regLen: uint64 = 0x04
    static let regData: uint64 = 0x08

    static let pageName: uint32 = 0x0_0000
    static let pageEvbits: uint32 = 0x1_0000
    static let pageAbsdata: uint32 = 0x2_0000 | evAbs

    static let evSyn: uint32 = 0
    static let evKey: uint32 = 1
    static let evAbs: uint32 = 3
    static let btnTouch: uint16 = 0x14a
    static let absX: uint16 = 0
    static let absY: uint16 = 1

    public let Name: string
    public let Width: int
    public let Height: int
    let irq: any device.Irq
    let lock = sync.Mutex()
    var page: uint32 = 0
    var queue: [uint32] = []
    var head = 0
    var touching = false

    /// A touchscreen of `width` × `height` (the screen's pixels) and a keyboard.
    public init(irq: any device.Irq, width: int, height: int, name: string = "qwerty2") {
        self.irq = irq
        Width = width
        Height = height
        Name = name
    }

    /// The bytes of the page selected, as REG_DATA serves them.
    func pageBytes() -> [uint8] {
        switch page {
        case GoldfishEvents.pageName:
            return [uint8](Name.utf8)
        case GoldfishEvents.pageEvbits | GoldfishEvents.evSyn:
            return [uint8(1 << GoldfishEvents.evSyn | 1 << GoldfishEvents.evKey | 1 << GoldfishEvents.evAbs)]
        case GoldfishEvents.pageEvbits | GoldfishEvents.evKey:
            // KEY_ESC..KEY_MICMUTE (1..248), and BTN_TOUCH.
            var bits = [uint8](repeating: 0, count: int(GoldfishEvents.btnTouch) / 8 + 1)
            for k in 1...248 { bits[k / 8] |= uint8(1 << (k % 8)) }
            bits[int(GoldfishEvents.btnTouch) / 8] |= uint8(1 << (int(GoldfishEvents.btnTouch) % 8))
            return bits
        case GoldfishEvents.pageEvbits | GoldfishEvents.evAbs:
            return [uint8(1 << GoldfishEvents.absX | 1 << GoldfishEvents.absY)]
        case GoldfishEvents.pageAbsdata:
            // min, max, fuzz, flat for ABS_X and ABS_Y, as 32-bit words.
            var b: [uint8] = []
            for v in [0, Width - 1, 0, 0, 0, Height - 1, 0, 0] {
                let u = uint32(v)
                b += [uint8(u & 0xff), uint8((u >> 8) & 0xff), uint8((u >> 16) & 0xff), uint8(u >> 24)]
            }
            return b
        default:
            return []
        }
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            switch offset {
            case GoldfishEvents.regRead:
                if head >= queue.count { return 0 }
                let w = queue[head]
                head += 1
                if head >= queue.count {
                    queue = []
                    head = 0
                    irq.Set(false)
                }
                return uint64(w)
            case GoldfishEvents.regLen:
                return uint64(pageBytes().count)
            default:
                if offset >= GoldfishEvents.regData {
                    let b = pageBytes()
                    let i = int(offset - GoldfishEvents.regData)
                    var v: uint64 = 0
                    for k in 0..<int(size) where i + k < b.count {
                        v |= uint64(b[i + k]) << uint64(8 * k)
                    }
                    return v
                }
                return 0
            }
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        if offset == GoldfishEvents.regSetPage {
            lock.withLock { page = uint32(truncatingIfNeeded: value) }
        }
    }

    func push(_ events: [(uint32, uint16, int32)]) {
        lock.withLock {
            for (t, c, v) in events {
                queue += [t, uint32(c), uint32(bitPattern: v)]
            }
            irq.Set(true)
        }
    }

    /// A key (an evdev KEY_ code) going down or up.
    public func Key(_ code: uint16, pressed: bool) {
        push([(GoldfishEvents.evKey, code, pressed ? 1 : 0), (GoldfishEvents.evSyn, 0, 0)])
    }

    /// A finger at (x, y) in screen pixels: down, moving, or lifted.
    public func Touch(x: int, y: int, down: bool) {
        let cx = int32(max(0, min(x, Width - 1)))
        let cy = int32(max(0, min(y, Height - 1)))
        var ev: [(uint32, uint16, int32)] = []
        let was = lock.withLock { touching }
        if down || was {
            ev.append((GoldfishEvents.evAbs, GoldfishEvents.absX, cx))
            ev.append((GoldfishEvents.evAbs, GoldfishEvents.absY, cy))
        }
        if down != was {
            ev.append((GoldfishEvents.evKey, GoldfishEvents.btnTouch, down ? 1 : 0))
            lock.withLock { touching = down }
        }
        if ev.isEmpty { return }
        ev.append((GoldfishEvents.evSyn, 0, 0))
        push(ev)
    }

    /// Whether a finger is down: a pointer moving without one is not a touch.
    public var Touching: bool { lock.withLock { touching } }
}
