package pci

import (
    "sync"
    "vm/device"
)

/// Where a platform puts the root complex: the ECAM window, and the MMIO
/// windows BARs are placed in.
public struct Layout {
    /// 1 MiB per bus; bus 0 only, so 1 MiB is enough.
    public let Ecam: device.Range
    /// Below 4 GiB, for 32-bit BARs.
    public let Mmio32: device.Range
    /// Above RAM, for 64-bit BARs.
    public let Mmio64: device.Range
    /// The first interrupt line INTA–INTD of each slot swizzle onto.
    public let IrqBase: uint32

    public init(ecam: device.Range, mmio32: device.Range, mmio64: device.Range, irqBase: uint32) {
        Ecam = ecam
        Mmio32 = mmio32
        Mmio64 = mmio64
        IrqBase = irqBase
    }
}

/// PciError is a function that doesn't fit.
public enum PciError: Error {
    case noSlot
    case noSpace(Bar)
}

/// Bus 0 of a PCIe root complex behind an ECAM window. It answers
/// configuration cycles, and it places BARs where the platform said. BARs
/// are placed once at Attach and never moved (firmware and OSes may
/// reprogram them; TODO(P4): honour that by re-inserting into the bus).
public struct Placement {
    public let Slot: int
    public let Bar: int
    public let Range: device.Range

    public init(slot: int, bar: int, range: device.Range) {
        Slot = slot
        Bar = bar
        Range = range
    }
}

final class SlotHolder {
    let function: any Function
    init(_ function: any Function) {
        self.function = function
    }
}

public final class Root: device.Mmio {
    public let Layout: Layout
    let lock = sync.Mutex()
    var slots: [int: SlotHolder] = [:]
    var next32: uint64
    var next64: uint64
    /// Where each slot's BARs landed: (slot, bar index, range).
    public private(set) var Placements: [Placement] = []

    public init(_ layout: Layout) {
        Layout = layout
        next32 = layout.Mmio32.Base
        next64 = layout.Mmio64.Base
    }

    /// Puts a function in the next free slot (slot 0 is the host bridge)
    /// and places its BARs. vm then inserts one BarWindow per placement
    /// into its MMIO bus.
    public func Attach(_ f: any Function) throws -> int {
        var foundSlot = -1
        for s in 1..<32 {
            if slots[s] == nil {
                foundSlot = s
                break
            }
        }
        if foundSlot < 0 {
            throw PciError.noSlot
        }
        let slot = foundSlot
        for bar in f.Bars {
            let is64 = bar.Kind == .memory64
            var at = is64 ? next64 : next32
            at = (at + bar.Size - 1) / bar.Size * bar.Size
            let limit = is64 ? Layout.Mmio64.End : Layout.Mmio32.End
            if at + bar.Size > limit {
                throw PciError.noSpace(bar)
            }
            if is64 { next64 = at + bar.Size } else { next32 = at + bar.Size }
            Placements.append(Placement(slot: slot, bar: bar.Index, range: device.Range(base: at, count: bar.Size)))
            // TODO(P4): write the BAR registers in f.Config so the guest reads them back.
        }
        slots[slot] = SlotHolder(f)
        return slot
    }

    /// The interrupt line a slot's INTA lands on (the standard swizzle).
    public func IntxLine(slot: int) -> uint32 {
        Layout.IrqBase + uint32(slot % 4)
    }

    // ECAM: offset = bus << 20 | device << 15 | function << 12 | register.
    public func Read(offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            let dev = int((offset >> 15) & 0x1f)
            let fn = (offset >> 12) & 0x7
            let reg = int(offset & 0xfff)
            if offset >> 20 != 0 || fn != 0 {
                return all1(size)
            }
            if dev == 0 {
                return uint64(hostBridge.Read(offset: reg, size: size))
            }
            guard let holder = slots[dev] else { return all1(size) }
            return uint64(holder.function.Config.Read(offset: reg, size: size))
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        lock.withLock {
            // TODO(P4): command register, BAR sizing (write all-ones, read the
            // size mask back), MSI-X message control, bridge registers.
        }
    }

    let hostBridge = ConfigSpace(vendor: 0x1b36, device: 0x0008, classCode: .hostBridge, revision: 0)

    func all1(_ size: uint8) -> uint64 {
        size >= 8 ? ~0 : (uint64(1) << (8 * uint64(size))) - 1
    }
}

/// One placed BAR as an MMIO device: what vm inserts into its bus for
/// each of Root.Placements.
public final class BarWindow: device.Mmio {
    let function: any Function
    let bar: int

    public init(_ function: any Function, bar: int) {
        self.function = function
        self.bar = bar
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        function.ReadBar(bar, offset: offset, size: size)
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        function.WriteBar(bar, offset: offset, size: size, value: value)
    }
}
