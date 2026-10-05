package virtio

import "vm/device"

/// One element of a descriptor chain: guest memory the device reads
/// (`Writable` false) or writes (true).
public struct Buffer {
    public let Address: device.GuestAddress
    public let Count: uint32
    public let Writable: bool
}

/// A chain the driver made available: its head index, and its buffers in
/// order (readable ones first, as the spec requires).
public struct Chain {
    public let Head: uint16
    public let Buffers: [Buffer]

    /// Total bytes the device may write.
    public var WritableCount: uint32 {
        Buffers.reduce(uint32(0)) { $1.Writable ? $0 + $1.Count : $0 }
    }
}

/// QueueError is a driver that broke the ring's rules. The device reports
/// it by setting NEEDS_RESET.
public enum QueueError: Error {
    case badDescriptor(uint16)
    case loop
    case writableBeforeReadable
    case notReady
}

let descFlagNext: uint16 = 1
let descFlagWrite: uint16 = 2
let descFlagIndirect: uint16 = 4

/// A split virtqueue (spec §2.7): descriptor table, available ring and
/// used ring, each at the guest address the driver gave.
public final class Queue {
    public let Index: int
    public var Size: uint16
    public var Descriptors: device.GuestAddress = device.GuestAddress(0)
    public var Available: device.GuestAddress = device.GuestAddress(0)
    public var Used: device.GuestAddress = device.GuestAddress(0)
    public var Ready = false
    /// Whether VIRTIO_F_EVENT_IDX was negotiated.
    public var EventIndex = false
    let memory: device.GuestMemory
    var lastAvailable: uint16 = 0
    var usedIndex: uint16 = 0

    public init(index: int, size: uint16, memory: device.GuestMemory) {
        Index = index
        Size = size
        self.memory = memory
    }

    /// The next chain the driver made available, or nil if there's none.
    public func Pop() throws -> Chain? {
        if !Ready { throw QueueError.notReady }
        let availIdx = try memory.Load16(Available.Adding(2))
        if availIdx == lastAvailable {
            return nil
        }
        let slot = uint64(lastAvailable % Size)
        let head = try memory.Load16(Available.Adding(4 + slot * 2))
        lastAvailable &+= 1
        return Chain(Head: head, Buffers: try walk(head))
    }

    func walk(_ head: uint16) throws -> [Buffer] {
        var out: [Buffer] = []
        var table = Descriptors
        var tableSize = Size
        var i = head
        var seen = 0
        var sawWritable = false
        while true {
            if i >= tableSize { throw QueueError.badDescriptor(i) }
            seen += 1
            if seen > int(tableSize) { throw QueueError.loop }
            let d = table.Adding(uint64(i) * 16)
            let addr = try memory.Load64(d)
            let len = try memory.Load32(d.Adding(8))
            let flags = try memory.Load16(d.Adding(12))
            let next = try memory.Load16(d.Adding(14))
            if flags & descFlagIndirect != 0 {
                // An indirect table replaces the rest of the chain.
                table = device.GuestAddress(addr)
                tableSize = uint16(len / 16)
                i = 0
                seen = 0
                continue
            }
            let writable = flags & descFlagWrite != 0
            if sawWritable && !writable { throw QueueError.writableBeforeReadable }
            sawWritable = sawWritable || writable
            out.append(Buffer(Address: device.GuestAddress(addr), Count: len, Writable: writable))
            if flags & descFlagNext == 0 {
                return out
            }
            i = next
        }
    }

    /// Returns a chain to the driver, saying how many bytes were written
    /// into it. Returns whether the driver wants an interrupt for it.
    public func Push(_ head: uint16, written: uint32) throws -> bool {
        let slot = uint64(usedIndex % Size)
        let elem = Used.Adding(4 + slot * 8)
        try memory.Store32(elem, uint32(head))
        try memory.Store32(elem.Adding(4), written)
        let old = usedIndex
        usedIndex &+= 1
        try memory.Store16(Used.Adding(2), usedIndex)
        return try needsInterrupt(old: old)
    }

    func needsInterrupt(old: uint16) throws -> bool {
        if EventIndex {
            // used_event sits after the available ring's entries.
            let usedEvent = try memory.Load16(Available.Adding(4 + uint64(Size) * 2))
            return (usedIndex &- usedEvent &- 1) < (usedIndex &- old)
        }
        let flags = try memory.Load16(Available)
        return flags & 1 == 0   // VIRTQ_AVAIL_F_NO_INTERRUPT
    }

    /// Copies the chain's readable bytes out of guest memory.
    public func ReadAll(_ chain: Chain) throws -> [uint8] {
        var out = [uint8]()
        let total = chain.Buffers.count
        var idx = 0
        while idx < total {
            let b = chain.Buffers[idx]
            if !b.Writable && b.Count > 0 {
                let chunk = try memory.Read(b.Address, count: int(b.Count))
                out.append(contentsOf: chunk)
            }
            idx += 1
        }
        return out
    }

    /// Copies bytes into the chain's writable buffers, in order. Returns
    /// how many fit.
    public func WriteAll(_ chain: Chain, _ bytes: borrowing [uint8]) throws -> uint32 {
        var done = 0
        let total = chain.Buffers.count
        var idx = 0
        while idx < total {
            let b = chain.Buffers[idx]
            if b.Writable && b.Count > 0 && done < bytes.count {
                let n = min(int(b.Count), bytes.count - done)
                if n > 0 {
                    try memory.Write(b.Address, Array(bytes[done..<done + n]))
                    done += n
                }
            }
            idx += 1
        }
        return uint32(done)
    }

    public func Reset() {
        Ready = false
        lastAvailable = 0
        usedIndex = 0
        Descriptors = device.GuestAddress(0)
        Available = device.GuestAddress(0)
        Used = device.GuestAddress(0)
    }
}
