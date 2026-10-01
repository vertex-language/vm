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
    /// The interrupt line INTA of slot 0 lands on; INTA–INTD of each slot
    /// swizzle across IrqBase...IrqBase+3.
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

/// Where Attach first placed a BAR. Firmware and OSes usually move BARs;
/// the windows decode wherever the guest last put them.
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

/// Bus 0 of a PCIe root complex behind an ECAM window. It answers
/// configuration cycles, gives each BAR a first address, and decodes
/// accesses to its MMIO windows by the BAR values the guest programmed.
public final class Root: device.Mmio {
    public let Layout: Layout
    let lock = sync.Mutex()
    var slots: [int: SlotHolder] = [:]
    var next32: uint64
    var next64: uint64
    let intx: ((uint32) -> any device.Irq)?
    /// Where each slot's BARs were first placed: (slot, bar index, range).
    public private(set) var Placements: [Placement] = []

    /// `intx` makes the interrupt line for a swizzled INTx number
    /// (Layout.IrqBase + 0...3); nil leaves functions unwired.
    public init(_ layout: Layout, intx: ((uint32) -> any device.Irq)? = nil) {
        Layout = layout
        next32 = layout.Mmio32.Base
        next64 = layout.Mmio64.Base
        self.intx = intx
    }

    /// Puts a function in the next free slot (slot 0 is the host bridge),
    /// gives its BARs first addresses and wires its INTA.
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
            let barOffset = 0x10 + 4 * bar.Index
            f.Config.Put32(barOffset, uint32(at & 0xffff_ffff) | barFlags(bar))
            if is64 {
                f.Config.Put32(barOffset + 4, uint32(at >> 32))
            }
        }
        if let make = intx {
            let line = IntxLine(slot: slot)
            f.Config.ConnectIntx(make(line), line: uint8(truncatingIfNeeded: line + 32))
        }
        lock.withLock { slots[slot] = SlotHolder(f) }
        return slot
    }

    /// The interrupt line a slot's INTA lands on (the standard swizzle).
    public func IntxLine(slot: int) -> uint32 {
        Layout.IrqBase + uint32(slot % 4)
    }

    func barFlags(_ bar: Bar) -> uint32 {
        var flags: uint32 = bar.Kind == .memory64 ? 0x04 : 0x00
        if bar.Kind == .io { flags = 0x01 }
        if bar.Prefetchable { flags |= 0x08 }
        return flags
    }

    // ECAM: offset = bus << 20 | device << 15 | function << 12 | register.
    public func Read(offset: uint64, size: uint8) -> uint64 {
        let dev = int((offset >> 15) & 0x1f)
        let fn = (offset >> 12) & 0x7
        let reg = int(offset & 0xfff)
        if offset >> 20 != 0 || fn != 0 {
            return all1(size)
        }
        if dev == 0 {
            return uint64(hostBridge.Read(offset: reg, size: size))
        }
        guard let holder = lock.withLock({ slots[dev] }) else { return all1(size) }
        return uint64(holder.function.Config.Read(offset: reg, size: size))
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        let dev = int((offset >> 15) & 0x1f)
        let fn = (offset >> 12) & 0x7
        let reg = int(offset & 0xfff)
        if offset >> 20 != 0 || fn != 0 || dev == 0 {
            return
        }
        guard let holder = lock.withLock({ slots[dev] }) else { return }
        let cfg = holder.function.Config
        let bars = holder.function.Bars

        // BARs (0x10..0x27): the address bits a BAR's size allows, so
        // writing all ones reads back the size mask.
        if reg >= 0x10 && reg < 0x28 {
            let dword = reg & ~3
            let shift = uint64(8 * (reg & 3))
            let old = uint64(cfg.Get32(dword))
            let width: uint64 = size >= 4 ? 0xffff_ffff : ((uint64(1) << (8 * uint64(size))) - 1) << shift
            let merged = (old & ~width) | ((value << shift) & width)
            let barIdx = (dword - 0x10) / 4
            if let bar = bars.first(where: { $0.Index == barIdx }) {
                let mask = uint32(~(bar.Size - 1) & 0xffff_ffff)
                cfg.Put32(dword, (uint32(merged & 0xffff_ffff) & mask) | barFlags(bar))
            } else if let bar = bars.first(where: { $0.Index == barIdx - 1 && $0.Kind == .memory64 }) {
                let maskHigh = uint32((~(bar.Size - 1) >> 32) & 0xffff_ffff)
                cfg.Put32(dword, uint32(merged & 0xffff_ffff) & maskHigh)
            }
            return
        }
        // Everything else, including the expansion ROM BAR (none: reads 0),
        // goes through the function's writable mask.
        cfg.GuestWrite(offset: reg, size: size, value: value)
    }

    /// The guest-physical range BAR `bar` of `f` decodes now, or nil when
    /// memory decoding is off or the BAR is unprogrammed.
    func decoded(_ f: any Function, _ bar: Bar) -> device.Range? {
        if !f.Config.MemoryEnabled { return nil }
        let off = 0x10 + 4 * bar.Index
        var base = uint64(f.Config.Get32(off) & 0xffff_fff0)
        if bar.Kind == .memory64 {
            base |= uint64(f.Config.Get32(off + 4)) << 32
        }
        if base == 0 { return nil }
        return device.Range(base: base, count: bar.Size)
    }

    /// An access to a BAR window: which function and BAR it hits, if any.
    func dispatch(_ address: uint64) -> (any Function, int, uint64)? {
        let holders = lock.withLock { Array(slots.values) }
        for h in holders {
            for bar in h.function.Bars where bar.Kind != .io {
                if let r = decoded(h.function, bar), address >= r.Base && address < r.End {
                    return (h.function, bar.Index, address - r.Base)
                }
            }
        }
        return nil
    }

    /// The MMIO device to insert over `range` (Layout.Mmio32 or Mmio64):
    /// it forwards each access to whichever BAR covers it now.
    public func MmioWindow(_ range: device.Range) -> Aperture {
        Aperture(root: self, base: range.Base)
    }

    let hostBridge = ConfigSpace(vendor: 0x1b36, device: 0x0008, classCode: .hostBridge, revision: 0)

    func all1(_ size: uint8) -> uint64 {
        size >= 8 ? ~0 : (uint64(1) << (8 * uint64(size))) - 1
    }
}

/// One of the root complex's MMIO apertures on the platform bus. Reads of
/// addresses no BAR covers return all ones; writes there are dropped.
public final class Aperture: device.Mmio {
    let root: Root
    let base: uint64

    init(root: Root, base: uint64) {
        self.root = root
        self.base = base
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        guard let (f, bar, off) = root.dispatch(base + offset) else { return root.all1(size) }
        return f.ReadBar(bar, offset: off, size: size)
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        guard let (f, bar, off) = root.dispatch(base + offset) else { return }
        f.WriteBar(bar, offset: off, size: size, value: value)
    }
}
