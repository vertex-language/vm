package chipset

import (
    "sync"
    "vm/device"
)

/// The ACPI Generic Event Device (ACPI 6.1+, "ACPI0013"): how a
/// hardware-reduced platform tells the guest about the power button (and,
/// later, memory and CPU hotplug). One event register the guest reads in
/// its _EVT method, an interrupt line, and a sleep/reset register pair
/// the FADT points at.
///
/// Layout: 0x0 event (read clears), 0x4 sleep control (write 5 << 2 | 1 << 5
/// for S5), 0x5 sleep status, 0x6 reset register.
public final class Ged: device.Mmio {
    public static let Size: uint64 = 0x10
    public static let PowerButton: uint32 = 1 << 0

    let irq: any device.Irq
    let lock = sync.Mutex()
    var events: uint32 = 0
    /// Called when the guest asks to power off or reset.
    public var OnPowerOff: (() -> Void)? = nil
    public var OnReset: (() -> Void)? = nil

    public init(irq: any device.Irq) {
        self.irq = irq
    }

    /// Presses the power button: the guest shuts down cleanly.
    public func PressPowerButton() {
        lock.withLock { events = events | Ged.PowerButton }
        irq.Pulse()
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            if offset == 0 {
                let e = events
                events = 0
                return uint64(e)
            }
            return 0
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        switch offset {
        case 0x4:
            // SLP_EN (bit 5) with SLP_TYP 5 (bits 2–4): S5, soft off.
            if value & (1 << 5) != 0 && (value >> 2) & 7 == 5 {
                OnPowerOff?()
            }
        case 0x6:
            if value == 1 { OnReset?() }
        default:
            break
        }
    }
}
