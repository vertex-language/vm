package virtio

import (
    "encoding/binary"
    "sync"
    "vm/disk"
)

/// virtio-blk (spec §5.2): a disk.Image as a block device with one
/// request queue.
public final class Block: Device {
    public let Id = DeviceId(rawValue: 2)
    let image: any disk.Image
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil
    let ioLock = sync.Mutex()

    static let featureReadOnly: uint64 = 1 << 5
    static let featureFlush: uint64 = 1 << 9
    static let featureDiscard: uint64 = 1 << 13
    static let featureWriteZeroes: uint64 = 1 << 14

    static let typeIn: uint32 = 0
    static let typeOut: uint32 = 1
    static let typeFlush: uint32 = 4
    static let typeGetId: uint32 = 8
    static let typeDiscard: uint32 = 11

    static let statusOk: uint8 = 0
    static let statusIoErr: uint8 = 1
    static let statusUnsupported: uint8 = 2

    public init(_ image: any disk.Image) {
        self.image = image
    }

    public var Features: uint64 {
        var f = CommonFeatures | Block.featureFlush | Block.featureDiscard
        if image.ReadOnly { f |= Block.featureReadOnly }
        return f
    }

    public var QueueSizes: [uint16] { [256] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 {
        // struct virtio_blk_config: capacity (in 512-byte sectors) at 0.
        var cfg = [uint8](repeating: 0, count: 64)
        binary.LittleEndian.PutUint64(&cfg, image.Size / 512, at: 0)
        binary.LittleEndian.PutUint32(&cfg, 128, at: 12)              // seg_max
        binary.LittleEndian.PutUint32(&cfg, 512, at: 20)              // blk_size
        binary.LittleEndian.PutUint32(&cfg, uint32(0xffff_ffff) / 512, at: 36)  // max_discard_sectors
        binary.LittleEndian.PutUint32(&cfg, 1, at: 40)                // max_discard_seg
        return readLE(cfg, offset, size)
    }

    public func WriteConfig(offset: uint64, size: uint8, value: uint64) {}

    public func Activate(queues: [Queue], features: uint64, notify: any Notifier) throws {
        self.queues = queues
        self.notify = notify
    }

    public func Reset() {
        queues = []
        notify = nil
    }

    public func Notified(queue index: int) {
        let q = queues[index]
        Task {
            await self.drain(q)
        }
    }

    func drain(_ q: Queue) async {
        while true {
            var item: Chain? = nil
            do {
                try ioLock.withLock {
                    item = try q.Pop()
                }
            } catch {
                item = nil
            }
            guard let chain = item else { break }

            let (status, written) = await handle(q, chain)
            // The last writable byte of every request is its status.
            if let last = chain.Buffers.last, last.Writable, last.Count > 0 {
                try? q.memory.Write(last.Address.Adding(uint64(last.Count - 1)), [status])
            }
            var needIntr = true
            ioLock.withLock {
                needIntr = (try? q.Push(chain.Head, written: written + 1)) ?? true
            }
            if needIntr {
                notify?.QueueUsed(q.Index)
            }
        }
    }

    func handle(_ q: Queue, _ chain: Chain) async -> (uint8, uint32) {
        guard let hdr = chain.Buffers.first, !hdr.Writable, hdr.Count >= 16,
              let h = try? q.memory.Read(hdr.Address, count: 16) else {
            return (Block.statusIoErr, 0)
        }
        let type = binary.LittleEndian.Uint32(h, from: 0)
        let sector = binary.LittleEndian.Uint64(h, from: 8)
        let totalBuffers = chain.Buffers.count
        do {
            switch type {
            case Block.typeIn:
                var offset = sector * 512
                var written: uint32 = 0
                var idx = 1
                while idx < totalBuffers - 1 {
                    let b = chain.Buffers[idx]
                    idx += 1
                    if !b.Writable || b.Count == 0 { continue }
                    var buf = [uint8](repeating: 0, count: int(b.Count))
                    try await image.ReadAt(offset, into: &buf)
                    try q.memory.Write(b.Address, buf)
                    offset += uint64(b.Count)
                    written += b.Count
                }
                return (Block.statusOk, written)
            case Block.typeOut:
                var offset = sector * 512
                var idx = 1
                while idx < totalBuffers - 1 {
                    let b = chain.Buffers[idx]
                    idx += 1
                    if b.Writable || b.Count == 0 { continue }
                    let buf = try q.memory.Read(b.Address, count: int(b.Count))
                    try await image.WriteAt(offset, buf)
                    offset += uint64(b.Count)
                }
                return (Block.statusOk, 0)
            case Block.typeFlush:
                try await image.Flush()
                return (Block.statusOk, 0)
            case Block.typeGetId:
                let id = Array("vertex-vm-disk".utf8)
                var written: uint32 = 0
                if totalBuffers >= 3 {
                    let b = chain.Buffers[1]
                    if b.Writable && b.Count > 0 {
                        let n = min(int(b.Count), 20, id.count)
                        try q.memory.Write(b.Address, Array(id[0..<n]))
                        written = uint32(n)
                    }
                }
                return (Block.statusOk, written)
            case Block.typeDiscard:
                var idx = 1
                while idx < totalBuffers - 1 {
                    let b = chain.Buffers[idx]
                    idx += 1
                    if b.Writable || b.Count < 16 { continue }
                    let seg = try q.memory.Read(b.Address, count: 16)
                    try await image.Discard(binary.LittleEndian.Uint64(seg, from: 0) * 512,
                                            count: uint64(binary.LittleEndian.Uint32(seg, from: 8)) * 512)
                }
                return (Block.statusOk, 0)
            default:
                return (Block.statusUnsupported, 0)
            }
        } catch {
            return (Block.statusIoErr, 0)
        }
    }
}

/// Reads `size` little-endian bytes of a config structure at `offset`.
package func readLE(_ cfg: [uint8], _ offset: uint64, _ size: uint8) -> uint64 {
    var v: uint64 = 0
    for i in 0..<int(size) {
        let at = int(offset) + i
        if at < cfg.count {
            v |= uint64(cfg[at]) << (8 * uint64(i))
        }
    }
    return v
}
