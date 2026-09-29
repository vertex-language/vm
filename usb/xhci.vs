package usb

import (
    "sync"
    "vm/device"
    "vm/pci"
)

/// An xHCI host controller (xHCI 1.2) on PCI: capability, operational,
/// runtime and doorbell registers in BAR 0; a command ring, one event ring,
/// a device context per slot; and a root hub with a port per device.
public final class Xhci: pci.Function {
    public let Config: pci.ConfigSpace
    let memory: device.GuestMemory
    let lock = sync.Mutex()
    var msix: pci.MsixTable
    public private(set) var Ports: [(any Device)?]

    // Register block offsets inside BAR 0.
    static let capLength: uint64 = 0x40
    static let runtimeBase: uint64 = 0x1000
    static let doorbellBase: uint64 = 0x2000

    var usbcmd: uint32 = 0
    var usbsts: uint32 = 1           // HCHalted
    var dcbaap: uint64 = 0
    var crcr: uint64 = 0
    var config: uint32 = 0

    public init(memory: device.GuestMemory, msi: any device.Msi, ports: int = 4) {
        self.memory = memory
        msix = pci.MsixTable(vectors: 1, msi: msi)
        Ports = [(any Device)?](repeating: nil, count: ports)
        Config = pci.ConfigSpace(vendor: 0x1b36, device: 0x000d, classCode: .xhci, revision: 1)
    }

    /// Plugs a device into the first free port; returns the port number (1-based).
    public func Plug(_ d: any Device) -> int? {
        guard let i = Ports.firstIndex(where: { $0 == nil }) else { return nil }
        Ports[i] = d
        // TODO(P4): port status change event if running.
        return i + 1
    }

    public var Bars: [pci.Bar] {
        [pci.Bar(index: 0, size: 0x4000, kind: .memory64, prefetchable: false)]
    }

    public func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            switch offset {
            case 0x00: return Xhci.capLength | (0x0120 << 16)                       // CAPLENGTH, HCIVERSION 1.2
            case 0x04: return uint64(64) | (1 << 8) | (uint64(Ports.count) << 24)  // HCSPARAMS1: slots, interrupters, ports
            case 0x08: return 0                                                     // HCSPARAMS2
            case 0x10: return 0x0000_0001 | (0x20 << 16)                            // HCCPARAMS1: 64-bit, xECP at 0x80
            case 0x14: return Xhci.doorbellBase
            case 0x18: return Xhci.runtimeBase
            case Xhci.capLength + 0x00: return uint64(usbcmd)
            case Xhci.capLength + 0x04: return uint64(usbsts)
            case Xhci.capLength + 0x08: return 1                                    // PAGESIZE: 4 KiB
            case Xhci.capLength + 0x38: return uint64(config)
            default:
                // TODO(P4): PORTSC per port at capLength + 0x400 + 0x10 * n,
                // extended capabilities (supported protocol USB 2 / 3), runtime
                // interrupter registers.
                return 0
            }
        }
    }

    public func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64) {
        lock.withLock {
            switch offset {
            case Xhci.capLength + 0x00:
                usbcmd = uint32(truncatingIfNeeded: value)
                if usbcmd & 1 != 0 { usbsts &= ~1 } else { usbsts |= 1 }
            case Xhci.capLength + 0x04:
                usbsts &= ~uint32(truncatingIfNeeded: value)                        // RW1C
            case Xhci.capLength + 0x18: crcr = value
            case Xhci.capLength + 0x30: dcbaap = value
            case Xhci.capLength + 0x38: config = uint32(truncatingIfNeeded: value)
            default:
                if offset >= Xhci.doorbellBase {
                    // TODO(P4): doorbell 0 runs the command ring (Enable Slot,
                    // Address Device, Configure Endpoint); doorbell n runs slot
                    // n's transfer rings and posts Transfer Events.
                }
            }
        }
    }
}
