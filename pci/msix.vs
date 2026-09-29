package pci

import (
    "sync"
    "vm/device"
)

/// An MSI-X table and pending-bit array (PCIe §6.1.4): per vector, the
/// address and data the guest programmed, and a mask bit.
public final class MsixTable {
    struct Entry {
        var address: uint64 = 0
        var data: uint32 = 0
        var masked = true
        var pending = false
    }

    let msi: any device.Msi
    let lock = sync.Mutex()
    var entries: [Entry]
    /// The function-wide enable and mask bits from the capability's
    /// message control.
    public var Enabled = false
    public var FunctionMasked = false

    public init(vectors: int, msi: any device.Msi) {
        self.msi = msi
        entries = [Entry](repeating: Entry(), count: vectors)
    }

    public var Vectors: int { entries.count }

    /// The MSI-X capability body for ConfigSpace.AddCapability(id: 0x11):
    /// table in `bar` at `tableOffset`, PBA at `pbaOffset`.
    public func Capability(bar: uint8, tableOffset: uint32, pbaOffset: uint32) -> [uint8] {
        let control = uint16(entries.count - 1)
        let t = tableOffset | uint32(bar)
        let p = pbaOffset | uint32(bar)
        return [uint8(control & 0xff), uint8(control >> 8),
                uint8(t & 0xff), uint8((t >> 8) & 0xff), uint8((t >> 16) & 0xff), uint8(t >> 24),
                uint8(p & 0xff), uint8((p >> 8) & 0xff), uint8((p >> 16) & 0xff), uint8(p >> 24)]
    }

    /// Raises vector `v`: sends it, or marks it pending while masked.
    public func Signal(_ v: int) {
        var send: (uint64, uint32)? = nil
        lock.withLock {
            if v >= entries.count || !Enabled { return }
            if entries[v].masked || FunctionMasked {
                entries[v].pending = true
            } else {
                send = (entries[v].address, entries[v].data)
            }
        }
        if let (a, d) = send {
            msi.Send(address: a, data: d)
        }
    }

    /// A guest access to the table (16 bytes per vector).
    public func ReadTable(offset: uint64, size: uint8) -> uint64 {
        let res: uint64 = lock.withLock {
            let v = int(offset / 16)
            if v >= entries.count { return uint64(0) }
            let e = entries[v]
            switch offset % 16 {
            case 0: return size == 8 ? e.address : e.address & 0xffff_ffff
            case 4: return e.address >> 32
            case 8: return uint64(e.data)
            case 12: return e.masked ? uint64(1) : uint64(0)
            default: return uint64(0)
            }
        }
        return res
    }

    public func WriteTable(offset: uint64, size: uint8, value: uint64) {
        var fire: (uint64, uint32)? = nil
        lock.withLock {
            let v = int(offset / 16)
            if v >= entries.count { return }
            switch offset % 16 {
            case 0:
                if size == 8 {
                    entries[v].address = value
                } else {
                    entries[v].address = (entries[v].address & 0xffff_ffff_0000_0000) | (value & 0xffff_ffff)
                }
            case 4: entries[v].address = (entries[v].address & 0xffff_ffff) | (value << 32)
            case 8: entries[v].data = uint32(truncatingIfNeeded: value)
            case 12:
                entries[v].masked = value & 1 != 0
                if !entries[v].masked && entries[v].pending {
                    entries[v].pending = false
                    fire = (entries[v].address, entries[v].data)
                }
            default: break
            }
        }
        if let (a, d) = fire {
            msi.Send(address: a, data: d)
        }
    }

    public func ReadPba(offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            var bits: uint64 = 0
            for i in 0..<64 {
                let v = int(offset) * 8 + i
                if v < entries.count && entries[v].pending {
                    bits |= 1 << uint64(i)
                }
            }
            return bits
        }
    }
}
