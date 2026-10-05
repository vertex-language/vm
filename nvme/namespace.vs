package nvme

import (
    "encoding/binary"
    "vm/device"
    "vm/disk"
)

/// One namespace: a disk image with 512-byte logical blocks.
public final class Namespace {
    public let Id: uint32
    public let Image: any disk.Image
    public let BlockSize: uint64 = 512

    init(id: uint32, image: any disk.Image) {
        Id = id
        Image = image
    }

    public var Blocks: uint64 { Image.Size / BlockSize }

    /// Identify Namespace (CNS 0): size, capacity, utilization and the
    /// one LBA format, 512-byte blocks.
    func Identify() -> [uint8] {
        var b = [uint8](repeating: 0, count: 4096)
        binary.LittleEndian.PutUint64(&b, Blocks, at: 0)     // NSZE
        binary.LittleEndian.PutUint64(&b, Blocks, at: 8)     // NCAP
        binary.LittleEndian.PutUint64(&b, Blocks, at: 16)    // NUSE
        b[24] = 0x01                        // NSFEAT: thin provisioning (deallocate reads as zeroes)
        b[25] = 0                           // NLBAF: one format
        b[26] = 0                           // FLBAS: format 0
        b[130] = 9                          // LBAF0: LBADS = 2^9
        return b
    }

    func Execute(_ cmd: Command, memory: device.GuestMemory) async -> (uint16, uint32) {
        let slba = uint64(cmd.Dword10) | (uint64(cmd.Dword11) << 32)
        let nlb = uint64(cmd.Dword12 & 0xffff) + 1
        switch cmd.Opcode {
        case 0x00:   // Flush
            do {
                try await Image.Flush()
                return (Status.success, 0)
            } catch {
                return (Status.dataTransferError, 0)
            }
        case 0x01, 0x02:   // Write, Read
            if slba + nlb > Blocks {
                return (Status.lbaOutOfRange, 0)
            }
            if cmd.Opcode == 0x01 && Image.ReadOnly {
                return (Status.writeProtected, 0)
            }
            do {
                let count = nlb * BlockSize
                let segs = try prpSegments(cmd, count: count, memory: memory)
                if cmd.Opcode == 0x02 {
                    var buf = [uint8](repeating: 0, count: int(count))
                    try await Image.ReadAt(slba * BlockSize, into: &buf)
                    try scatter(buf, segs, memory: memory)
                } else {
                    let buf = try gather(segs, memory: memory)
                    try await Image.WriteAt(slba * BlockSize, buf)
                }
                return (Status.success, 0)
            } catch {
                return (Status.dataTransferError, 0)
            }
        case 0x08:   // Write Zeroes
            if slba + nlb > Blocks {
                return (Status.lbaOutOfRange, 0)
            }
            if Image.ReadOnly {
                return (Status.writeProtected, 0)
            }
            let zeroes = [uint8](repeating: 0, count: int(nlb * BlockSize))
            do {
                try await Image.WriteAt(slba * BlockSize, zeroes)
                return (Status.success, 0)
            } catch {
                return (Status.dataTransferError, 0)
            }
        case 0x09:   // Dataset Management: deallocate each range
            let ranges = int(cmd.Dword10 & 0xff) + 1
            if cmd.Dword11 & 0x4 == 0 || Image.ReadOnly {
                return (Status.success, 0)   // only hints, or nothing to free
            }
            do {
                let segs = try prpSegments(cmd, count: uint64(ranges * 16), memory: memory)
                let list = try gather(segs, memory: memory)
                for r in 0..<ranges {
                    let length = uint64(binary.LittleEndian.Uint32(list, from: r * 16 + 4))
                    let start = binary.LittleEndian.Uint64(list, from: r * 16 + 8)
                    if start + length <= Blocks {
                        try await Image.Discard(start * BlockSize, count: length * BlockSize)
                    }
                }
                return (Status.success, 0)
            } catch {
                return (Status.dataTransferError, 0)
            }
        default:
            return (Status.invalidOpcode, 0)
        }
    }
}
