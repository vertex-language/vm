package boot

import (
    "sync"
    "vm/device"
)

/// fw_cfg: the channel stock EDK2 builds read the machine from. It's a
/// selector register, a data register and a DMA register, over a directory
/// of named files ("etc/acpi/tables", "etc/table-loader", "bootorder",
/// "etc/ramfb"). A QEMU interface, but small, and it's what lets
/// unmodified firmware from any distribution boot here.
///
/// MMIO layout (arm64, and amd64 as MMIO too): data at 0, selector at 8,
/// DMA address at 16.
public final class FwCfg: device.Mmio {
    public struct File {
        public let Name: string
        public var Bytes: [uint8]
        /// Called when the guest writes the file (ramfb's config).
        public var OnWrite: (([uint8]) -> Void)? = nil

        public init(name: string, bytes: [uint8], onWrite: (([uint8]) -> Void)? = nil) {
            Name = name
            Bytes = bytes
            OnWrite = onWrite
        }
    }

    static let selSignature: uint16 = 0x0000
    static let selId: uint16 = 0x0001
    static let selFileDir: uint16 = 0x0019
    static let firstFile: uint16 = 0x0020

    let lock = sync.Mutex()
    var files: [File] = []
    var selector: uint16 = 0
    var position = 0
    let memory: device.GuestMemory

    public init(memory: device.GuestMemory) {
        self.memory = memory
    }

    /// Adds a file; files are listed in the order added.
    public func Add(_ f: File) {
        lock.withLock { files.append(f) }
    }

    func current() -> [uint8] {
        switch selector {
        case FwCfg.selSignature:
            return Array("QEMU".utf8)                 // the signature firmware checks for
        case FwCfg.selId:
            return [3, 0, 0, 0]                       // traditional + DMA interface
        case FwCfg.selFileDir:
            return directory()
        default:
            let i = int(selector) - int(FwCfg.firstFile)
            return i >= 0 && i < files.count ? files[i].Bytes : []
        }
    }

    func directory() -> [uint8] {
        // Big-endian: count, then per file size, select, reserved, 56-byte name.
        var b: [uint8] = []
        func be32(_ v: uint32) { b.append(contentsOf: [uint8(v >> 24), uint8((v >> 16) & 0xff), uint8((v >> 8) & 0xff), uint8(v & 0xff)]) }
        be32(uint32(files.count))
        for (i, f) in files.enumerated() {
            be32(uint32(f.Bytes.count))
            let sel = FwCfg.firstFile + uint16(i)
            b.append(contentsOf: [uint8(sel >> 8), uint8(sel & 0xff), 0, 0])
            var name = Array(f.Name.utf8)
            name.append(contentsOf: [uint8](repeating: 0, count: 56 - min(56, name.count)))
            b.append(contentsOf: name[0..<56])
        }
        return b
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        let res: uint64 = lock.withLock {
            if offset != 0 { return uint64(0) }
            let data = current()
            var v: uint64 = 0
            // The data register is a byte stream; wide reads are big-endian.
            for _ in 0..<int(size) {
                v <<= 8
                if position < data.count {
                    v |= uint64(data[position])
                }
                position += 1
            }
            return v
        }
        return res
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        lock.withLock {
            switch offset {
            case 8:
                // The selector is big-endian on MMIO.
                let v = uint16(truncatingIfNeeded: value)
                selector = (v >> 8) | (v << 8)
                position = 0
            case 16, 20:
                // TODO(P4): DMA: FWCfgDmaAccess { be32 control; be32 length;
                // be64 address } at the written guest address; control bits
                // read (2), skip (4), select (8), write (16).
                break
            default:
                break
            }
        }
    }
}
