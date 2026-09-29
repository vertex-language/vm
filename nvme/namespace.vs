package nvme

import (
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

    func Execute(_ cmd: Command, memory: device.GuestMemory) async -> (uint16, uint32) {
        let slba = uint64(cmd.Dword10) | (uint64(cmd.Dword11) << 32)
        let nlb = uint64(cmd.Dword12 & 0xffff) + 1
        switch cmd.Opcode {
        case 0x00:   // Flush
            return (try? await Image.Flush()) != nil ? (Status.success, 0) : (Status.dataTransferError, 0)
        case 0x01, 0x02:   // Write, Read
            if slba + nlb > Blocks {
                return (Status.lbaOutOfRange, 0)
            }
            do {
                let count = nlb * BlockSize
                let pages = try prpPages(cmd, count: count, memory: memory)
                var done: uint64 = 0
                for p in pages where done < count {
                    let n = min(4096 - p.Value % 4096, count - done)
                    if cmd.Opcode == 0x02 {
                        var buf = [uint8](repeating: 0, count: int(n))
                        try await Image.ReadAt(slba * BlockSize + done, into: &buf)
                        try memory.Write(p, buf)
                    } else {
                        let buf = try memory.Read(p, count: int(n))
                        try await Image.WriteAt(slba * BlockSize + done, buf)
                    }
                    done += n
                }
                return (Status.success, 0)
            } catch {
                return (Status.dataTransferError, 0)
            }
        case 0x09:   // Dataset Management (deallocate)
            // TODO(P4): read the range list at PRP1 and Discard each range.
            return (Status.success, 0)
        default:
            return (Status.invalidOpcode, 0)
        }
    }
}
