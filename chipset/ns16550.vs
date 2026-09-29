// Package chipset is the small fixed devices every platform has: a
// serial port, a real-time clock, an IOAPIC where the hypervisor has none,
// and the ACPI Generic Event Device for the power button.
//
// Files are named for the part, not the architecture, so cmd/check tests
// every model on every host; vm's platform files choose which to place.
package chipset

import (
    "io"
    "sync"
    "vm/device"
)

/// A 16550A UART: the amd64 serial port at 0x3f8 (COM1), IRQ 4. Linux
/// ttyS0, Windows EMS, and firmware debug output all use it. Transmit goes
/// straight to `output`; receive is fed by `Feed`.
public final class Ns16550: device.Pio, device.Mmio {
    let output: any io.AsyncWriter
    let irq: any device.Irq
    let lock = sync.Mutex()
    var rx: [uint8] = []
    var ier: uint8 = 0
    var lcr: uint8 = 0
    var mcr: uint8 = 0
    var scr: uint8 = 0
    var dll: uint8 = 1
    var dlm: uint8 = 0

    public init(output: any io.AsyncWriter, irq: any device.Irq) {
        self.output = output
        self.irq = irq
    }

    /// Bytes the guest will read, from the host's terminal.
    public func Feed(_ bytes: [uint8]) {
        lock.withLock { rx.append(contentsOf: bytes) }
        update()
    }

    var dlab: bool { lcr & 0x80 != 0 }

    func reg(_ r: uint64) -> uint8 {
        lock.withLock {
            switch r {
            case 0:
                if dlab { return dll }
                return rx.isEmpty ? 0 : rx.removeFirst()
            case 1: return dlab ? dlm : ier
            case 2: return rx.isEmpty ? 0xc1 : 0xc4               // IIR: FIFOs on; rx data pending
            case 3: return lcr
            case 4: return mcr
            case 5: return 0x60 | (rx.isEmpty ? 0 : 1)             // LSR: THR empty, TX idle, data ready
            case 6: return 0xb0                                    // MSR: DCD, DSR, CTS
            case 7: return scr
            default: return 0
            }
        }
    }

    func set(_ r: uint64, _ v: uint8) {
        var out: uint8? = nil
        lock.withLock {
            switch r {
            case 0: if dlab { dll = v } else { out = v }
            case 1: if dlab { dlm = v } else { ier = v & 0x0f }
            case 3: lcr = v
            case 4: mcr = v
            case 7: scr = v
            default: break
            }
        }
        if let b = out {
            Task { try? await self.output.Write([b]) }
        }
        update()
    }

    func update() {
        let pending = lock.withLock { (ier & 1 != 0 && !rx.isEmpty) || ier & 2 != 0 }
        irq.Set(pending)
    }

    public func Read(port: uint16, size: uint8) -> uint32 { uint32(reg(uint64(port & 7))) }
    public func Write(port: uint16, size: uint8, value: uint32) { set(uint64(port & 7), uint8(truncatingIfNeeded: value)) }
    public func Read(offset: uint64, size: uint8) -> uint64 { uint64(reg(offset & 7)) }
    public func Write(offset: uint64, size: uint8, value: uint64) { set(offset & 7, uint8(truncatingIfNeeded: value)) }
}
