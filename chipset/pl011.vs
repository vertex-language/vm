package chipset

import (
    "io"
    "sync"
    "vm/device"
)

/// An Arm PL011 UART: the arm64 serial port (ttyAMA0, and SPCR's console
/// for Windows on ARM). 4 KiB of registers, with the PrimeCell ID
/// registers at the end so drivers recognise it.
public final class Pl011: device.Mmio {
    let output: any io.AsyncWriter
    let irq: any device.Irq
    let lock = sync.Mutex()
    var rx: [uint8] = []
    var imsc: uint32 = 0      // interrupt mask
    var ris: uint32 = 0       // raw interrupt status
    var cr: uint32 = 0x300
    var lcr: uint32 = 0
    var ibrd: uint32 = 0
    var fbrd: uint32 = 0
    var ifls: uint32 = 0x12

    static let rxInterrupt: uint32 = 1 << 4
    static let txInterrupt: uint32 = 1 << 5
    static let id: [uint8] = [0x11, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1]

    public init(output: any io.AsyncWriter, irq: any device.Irq) {
        self.output = output
        self.irq = irq
    }

    public func Feed(_ bytes: [uint8]) {
        lock.withLock {
            rx.append(contentsOf: bytes)
            ris |= Pl011.rxInterrupt
        }
        update()
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        let v: uint32 = lock.withLock {
            switch offset {
            case 0x000:
                let b = rx.isEmpty ? 0 : uint32(rx.removeFirst())
                if rx.isEmpty { ris &= ~Pl011.rxInterrupt }
                return b
            case 0x018: return (rx.isEmpty ? 0x10 : 0) | 0x80        // FR: RXFE, TXFE
            case 0x024: return ibrd
            case 0x028: return fbrd
            case 0x02c: return lcr
            case 0x030: return cr
            case 0x034: return ifls
            case 0x038: return imsc
            case 0x03c: return ris
            case 0x040: return ris & imsc
            default:
                if offset >= 0xfe0 && offset < 0x1000 {
                    return uint32(Pl011.id[int((offset - 0xfe0) / 4)])
                }
                return 0
            }
        }
        update()
        return uint64(v)
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        let v = uint32(truncatingIfNeeded: value)
        var out: uint8? = nil
        lock.withLock {
            switch offset {
            case 0x000:
                out = uint8(v & 0xff)
                ris |= Pl011.txInterrupt
            case 0x024: ibrd = v
            case 0x028: fbrd = v
            case 0x02c: lcr = v
            case 0x030: cr = v
            case 0x034: ifls = v
            case 0x038: imsc = v
            case 0x044: ris &= ~v                                   // ICR
            default: break
            }
        }
        if let b = out {
            Task { try? await self.output.Write([b]) }
        }
        update()
    }

    func update() {
        irq.Set(lock.withLock { ris & imsc != 0 })
    }
}
