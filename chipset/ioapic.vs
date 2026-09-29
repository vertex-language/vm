package chipset

import (
    "sync"
    "vm/device"
)

/// An 82093AA IOAPIC at 0xfec0_0000: 24 pins, each with a redirection
/// entry the guest programs (vector, delivery mode, destination, mask,
/// trigger). vm places it only where the hypervisor has no in-kernel one
/// (WHP). A raised pin becomes an MSI-style write to the LAPIC.
public final class IoApic: device.Mmio {
    public static let Pins = 24

    let msi: any device.Msi
    let lock = sync.Mutex()
    var select: uint32 = 0
    var id: uint32 = 0
    var redirection = [uint64](repeating: 1 << 16, count: 24)   // all masked
    var level = [bool](repeating: false, count: 24)
    var remoteIrr = [bool](repeating: false, count: 24)

    public init(msi: any device.Msi) {
        self.msi = msi
    }

    /// The Irq for one pin, to hand a device.
    public func Pin(_ n: int) -> any device.Irq {
        IoApicPin(apic: self, pin: n)
    }

    func set(_ pin: int, _ high: bool) {
        var deliver: (uint64, uint32)? = nil
        lock.withLock {
            let r = redirection[pin]
            let masked = r & (1 << 16) != 0
            let levelTriggered = r & (1 << 15) != 0
            let rising = high && !level[pin]
            level[pin] = high
            if masked || !high { return }
            if levelTriggered {
                if remoteIrr[pin] { return }
                remoteIrr[pin] = true
            } else if !rising {
                return
            }
            let vector = uint32(r & 0xff)
            let mode = uint32((r >> 8) & 7)
            let logical = r & (1 << 11) != 0
            let dest = (r >> 56) & 0xff
            let address: uint64 = 0xfee0_0000 | (dest << 12) | (logical ? 1 << 2 : 0)
            let data = vector | (mode << 8) | (levelTriggered ? 1 << 15 : 0)
            deliver = (address, data)
        }
        if let (a, d) = deliver {
            msi.Send(address: a, data: d)
        }
    }

    /// The guest's EOI for `vector` (forwarded by the LAPIC): clears
    /// Remote IRR, and redelivers if the line is still high.
    public func EndOfInterrupt(_ vector: uint8) {
        var again: [int] = []
        lock.withLock {
            for p in 0..<IoApic.Pins where uint8(redirection[p] & 0xff) == vector && remoteIrr[p] {
                remoteIrr[p] = false
                if level[p] { again.append(p) }
            }
        }
        for p in again { set(p, true) }
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            if offset == 0x00 { return uint64(select) }
            if offset != 0x10 { return 0 }
            switch select {
            case 0x00: return uint64(id << 24)
            case 0x01: return uint64(0x11 | ((IoApic.Pins - 1) << 16))    // version, max entry
            case 0x02: return 0
            default:
                let i = int(select - 0x10)
                if i < 0 || i >= IoApic.Pins * 2 { return 0 }
                var r = redirection[i / 2]
                if remoteIrr[i / 2] { r |= 1 << 14 }
                return i % 2 == 0 ? r & 0xffff_ffff : r >> 32
            }
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        var retrigger: int? = nil
        lock.withLock {
            let v = uint32(truncatingIfNeeded: value)
            if offset == 0x00 {
                select = v & 0xff
                return
            }
            if offset != 0x10 { return }
            if select == 0x00 {
                id = (v >> 24) & 0xf
                return
            }
            let i = int(select) - 0x10
            if i < 0 || i >= IoApic.Pins * 2 { return }
            let pin = i / 2
            if i % 2 == 0 {
                redirection[pin] = (redirection[pin] & 0xffff_ffff_0000_0000) | uint64(v & ~(1 << 14))
            } else {
                redirection[pin] = (redirection[pin] & 0xffff_ffff) | (uint64(v) << 32)
            }
            if redirection[pin] & (1 << 16) == 0 && level[pin] { retrigger = pin }
        }
        if let p = retrigger { set(p, true) }
    }
}

final class IoApicPin: device.Irq {
    let apic: IoApic
    let pin: int

    init(apic: IoApic, pin: int) {
        self.apic = apic
        self.pin = pin
    }

    func Set(_ level: bool) { apic.set(pin, level) }

    func Pulse() {
        apic.set(pin, true)
        apic.set(pin, false)
    }
}
