package chipset

import (
    "sync"
    "time"
    "vm/device"
)

/// The MC146818 CMOS real-time clock at ports 0x70–0x71: the amd64 RTC.
/// Windows keeps it in local time; Linux and the BSDs in UTC. `LocalTime`
/// picks which the guest sees.
public final class Cmos: device.Pio {
    public let LocalTime: bool
    let lock = sync.Mutex()
    var index: uint8 = 0
    var ram = [uint8](repeating: 0, count: 128)
    /// Seconds the guest has moved its clock from the host's.
    var offset: int64 = 0

    public init(localTime: bool, memoryBelow4G: uint64 = 0, memoryAbove4G: uint64 = 0) {
        LocalTime = localTime
        ram[0x0a] = 0x26          // register A: 32.768 kHz, 1024 Hz
        ram[0x0b] = 0x02          // register B: 24-hour, BCD
        ram[0x0d] = 0x80          // register D: valid RAM and time
        // TODO(P5): memory size bytes (0x34/0x35, 0x5b–0x5d) for firmware that reads them.
    }

    func bcd(_ v: int) -> uint8 {
        uint8((v / 10) << 4 | (v % 10))
    }

    struct Date {
        var Year: int = 2026
        var Month: int = 9
        var Day: int = 29
        var Hour: int = 0
        var Minute: int = 0
        var Second: int = 0
        var Weekday: int = 2
    }

    func now() -> Date {
        let t = time.Timestamp.Now().UnixSeconds + offset
        let secs = t % 86400
        let hour = int(secs / 3600)
        let min = int((secs / 60) % 60)
        let sec = int(secs % 60)
        return Date(Year: 2026, Month: 9, Day: 29, Hour: hour, Minute: min, Second: sec, Weekday: 2)
    }

    public func Read(port: uint16, size: uint8) -> uint32 {
        if port & 1 == 0 { return 0xff }
        return lock.withLock {
            let d = now()
            switch index {
            case 0x00: return uint32(bcd(d.Second))
            case 0x02: return uint32(bcd(d.Minute))
            case 0x04: return uint32(bcd(d.Hour))
            case 0x06: return uint32(d.Weekday + 1)
            case 0x07: return uint32(bcd(d.Day))
            case 0x08: return uint32(bcd(d.Month))
            case 0x09: return uint32(bcd(d.Year % 100))
            case 0x32: return uint32(bcd(d.Year / 100))
            case 0x0a: return uint32(ram[0x0a])      // UIP never set: reads are atomic here
            default: return uint32(ram[int(index & 0x7f)])
            }
        }
    }

    public func Write(port: uint16, size: uint8, value: uint32) {
        lock.withLock {
            if port & 1 == 0 {
                index = uint8(value & 0x7f)          // bit 7 is the NMI mask
            } else {
                // TODO(P5): time writes adjust `offset` rather than the host clock.
                ram[int(index)] = uint8(truncatingIfNeeded: value)
            }
        }
    }
}
