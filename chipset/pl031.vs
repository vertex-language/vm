package chipset

import (
    "sync"
    "time"
    "vm/device"
)

/// An Arm PL031 real-time clock: seconds since the epoch in one register.
/// The arm64 RTC. Like Cmos, it can show local time for Windows.
public final class Pl031: device.Mmio {
    public let LocalTime: bool
    let irq: any device.Irq
    let lock = sync.Mutex()
    var offset: int64 = 0
    var match: uint32 = 0
    var control: uint32 = 1

    static let id: [uint8] = [0x31, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1]

    public init(irq: any device.Irq = device.NoIrq(), localTime: bool = false) {
        self.irq = irq
        self.LocalTime = localTime
    }

    func seconds() -> uint32 {
        let t = time.Timestamp.Now().UnixSeconds + offset
        return uint32(truncatingIfNeeded: t)
    }

    public func Read(offset o: uint64, size: uint8) -> uint64 {
        lock.withLock {
            switch o {
            case 0x00: return uint64(seconds())      // DR
            case 0x04: return uint64(match)          // MR
            case 0x0c: return uint64(control)        // CR
            default:
                if o >= 0xfe0 && o < 0x1000 {
                    return uint64(Pl031.id[int((o - 0xfe0) / 4)])
                }
                return 0
            }
        }
    }

    public func Write(offset o: uint64, size: uint8, value: uint64) {
        lock.withLock {
            switch o {
            case 0x04: match = uint32(truncatingIfNeeded: value)
            case 0x08: offset = int64(uint32(truncatingIfNeeded: value)) - int64(seconds()) + offset   // LR
            case 0x0c: control = uint32(truncatingIfNeeded: value) & 1
            default: break
            }
        }
    }
}
