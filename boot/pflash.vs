package boot

import (
    "sync"
    "vm/device"
    "vm/disk"
)

/// A CFI parallel flash bank (Intel command set, as QEMU's pflash_cfi01):
/// what EDK2 reads its code from and writes its variables to. Reads are
/// plain memory while the bank is in read-array mode; writes are commands.
///
/// TODO(P4): map the code bank read-only straight into the partition so
/// instruction fetches never exit; only the vars bank needs this device.
public final class Pflash: device.Mmio {
    let backing: any disk.Image
    let lock = sync.Mutex()
    var contents: [uint8]
    var mode: uint8 = 0xff        // 0xff read array, 0x70 read status, 0x90 read id, 0x98 CFI query
    var pendingWrite: uint64? = nil
    public let ReadOnly: bool

    public init(contents: [uint8], size: uint64, backing: any disk.Image, readOnly: bool) {
        var c = contents
        if uint64(c.count) < size {
            c.append(contentsOf: [uint8](repeating: 0xff, count: int(size) - c.count))
        }
        self.contents = c
        self.backing = backing
        ReadOnly = readOnly
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        let res: uint64 = lock.withLock {
            switch mode {
            case 0x70:
                return uint64(0x80)   // status: ready
            case 0x90:
                return offset == 0 ? uint64(0x89) : (offset == 1 ? uint64(0x18) : uint64(0))   // Intel, device id
            case 0x98:
                return cfiQuery(offset)
            default:
                var v: uint64 = 0
                for i in 0..<int(size) where int(offset) + i < contents.count {
                    v |= uint64(contents[int(offset) + i]) << (8 * uint64(i))
                }
                return v
            }
        }
        return res
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        lock.withLock {
            if ReadOnly { return }
            let cmd = uint8(truncatingIfNeeded: value)
            if pendingWrite != nil {
                // Byte program: 0x10 / 0x40 then the data.
                contents[int(offset)] = contents[int(offset)] & cmd   // flash only clears bits
                pendingWrite = nil
                mode = 0x70
                persist(offset, 1)
                return
            }
            switch cmd {
            case 0x10, 0x40: pendingWrite = offset
            case 0x20:
                mode = 0x20                                           // block erase: confirmed by 0xd0
            case 0xd0:
                if mode == 0x20 {
                    let block = offset / 0x4_0000 * 0x4_0000
                    for i in 0..<0x4_0000 where int(block) + i < contents.count {
                        contents[int(block) + i] = 0xff
                    }
                    persist(block, 0x4_0000)
                }
                mode = 0x70
            case 0x50: mode = 0xff                                    // clear status
            case 0x70, 0x90, 0x98, 0xff: mode = cmd
            default: mode = 0xff
            }
        }
    }

    func persist(_ offset: uint64, _ count: uint64) {
        let slice = Array(contents[int(offset)..<min(contents.count, int(offset + count))])
        Task { try? await self.backing.WriteAt(offset, slice) }
    }

    func cfiQuery(_ offset: uint64) -> uint64 {
        // TODO(P4): the CFI query table ("QRY", sizes, erase block regions).
        switch offset {
        case 0x10: return 0x51   // 'Q'
        case 0x11: return 0x52   // 'R'
        case 0x12: return 0x59   // 'Y'
        default: return 0
        }
    }
}
