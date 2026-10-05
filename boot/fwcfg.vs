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
            // The data register is a byte stream; CPU registers receive byte 0 in bits 0..7.
            for i in 0..<int(size) {
                if position < data.count {
                    v |= uint64(data[position]) << (8 * uint64(i))
                }
                position += 1
            }
            return v
        }
        return res
    }

    static let dmaCtlError: uint32 = 0x01
    static let dmaCtlRead: uint32 = 0x02
    static let dmaCtlSkip: uint32 = 0x04
    static let dmaCtlSelect: uint32 = 0x08
    static let dmaCtlWrite: uint32 = 0x10

    var dmaHigh: uint32 = 0

    func executeDma(_ dmaAddr: uint64) {
        guard let desc = try? memory.Read(device.GuestAddress(dmaAddr), count: 16) else {
            print("[fw_cfg] executeDma failed to read descriptor at 0x\(string(dmaAddr, radix: 16))")
            return
        }
        // Big-endian descriptor: control (u32), length (u32), address (u64)
        let ctl = (uint32(desc[0]) << 24) | (uint32(desc[1]) << 16) | (uint32(desc[2]) << 8) | uint32(desc[3])
        let len = (uint32(desc[4]) << 24) | (uint32(desc[5]) << 16) | (uint32(desc[6]) << 8) | uint32(desc[7])
        var bufAddr: uint64 = 0
        for b in 0..<8 {
            bufAddr = (bufAddr << 8) | uint64(desc[8 + b])
        }

        var hasError = false

        if (ctl & FwCfg.dmaCtlSelect) != 0 {
            selector = uint16(ctl >> 16)
            position = 0
        }

        if (ctl & FwCfg.dmaCtlRead) != 0 {
            let data = current()
            let available = max(0, data.count - position)
            let toRead = min(int(len), available)
            if toRead > 0 {
                let slice = Array(data[position..<(position + toRead)])
                do {
                    try memory.Write(device.GuestAddress(bufAddr), slice)
                } catch {
                    hasError = true
                }
                position += toRead
            }
            if int(len) > toRead {
                let padding = [uint8](repeating: 0, count: int(len) - toRead)
                do {
                    try memory.Write(device.GuestAddress(bufAddr + uint64(toRead)), padding)
                } catch {
                    hasError = true
                }
                position += (int(len) - toRead)
            }
        } else if (ctl & FwCfg.dmaCtlWrite) != 0 {
            if let writeBytes = try? memory.Read(device.GuestAddress(bufAddr), count: int(len)) {
                let i = int(selector) - int(FwCfg.firstFile)
                if i >= 0 && i < files.count {
                    files[i].OnWrite?(writeBytes)
                }
            } else {
                hasError = true
            }
        } else if (ctl & FwCfg.dmaCtlSkip) != 0 {
            position += int(len)
        }

        // Clear control flags in descriptor to signal DMA completion
        var resultCtl: [uint8] = [0, 0, 0, 0]
        if hasError {
            resultCtl[3] = uint8(FwCfg.dmaCtlError)
        }
        try? memory.Write(device.GuestAddress(dmaAddr), resultCtl)
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        lock.withLock {
            switch offset {
            case 8:
                // The selector is big-endian on MMIO.
                let v = uint16(truncatingIfNeeded: value)
                selector = (v >> 8) | (v << 8)
                position = 0
            case 16:
                if size == 8 {
                    // 64-bit store of big-endian address: swap to get host physical address
                    var dmaAddr: uint64 = 0
                    var v = value
                    for _ in 0..<8 {
                        dmaAddr = (dmaAddr << 8) | (v & 0xff)
                        v >>= 8
                    }
                    executeDma(dmaAddr)
                } else if size == 4 {
                    dmaHigh = uint32(truncatingIfNeeded: value)
                }
            case 20:
                if size == 4 {
                    let dmaLow = uint32(truncatingIfNeeded: value)
                    let dmaAddr = (uint64(dmaHigh) << 32) | uint64(dmaLow)
                    executeDma(dmaAddr)
                }
            default:
                break
            }
        }
    }
}
