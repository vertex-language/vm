package nvme

import (
    "encoding/binary"
    "sync"
    "vm/device"
)

/// A 64-byte submission queue entry, decoded.
public struct Command {
    public let Opcode: uint8
    public let Id: uint16
    public let Namespace: uint32
    public let Prp1: uint64
    public let Prp2: uint64
    public let Dword10: uint32
    public let Dword11: uint32
    public let Dword12: uint32
    public let Dword13: uint32
}

/// A submission queue in guest memory. The guest moves Tail by doorbell;
/// the controller moves Head as it takes commands.
public final class SubmissionQueue {
    public let Id: int
    public let CompletionQueue: int
    let base: device.GuestAddress
    let size: uint16
    let memory: device.GuestMemory
    public var Head: uint16 = 0
    public var Tail: uint16 = 0
    /// A task is taking commands off this queue; another doorbell leaves
    /// them to it.
    var draining = false

    init(id: int, base: device.GuestAddress, size: uint16, cq: int, memory: device.GuestMemory) {
        Id = id
        self.base = base
        self.size = size
        CompletionQueue = cq
        self.memory = memory
    }

    func Pop() throws -> Command? {
        if Head == Tail { return nil }
        let e = try memory.Read(base.Adding(uint64(Head) * 64), count: 64)
        Head = (Head + 1) % size
        return Command(
            Opcode: e[0],
            Id: binary.LittleEndian.Uint16(e, from: 2),
            Namespace: binary.LittleEndian.Uint32(e, from: 4),
            Prp1: binary.LittleEndian.Uint64(e, from: 24),
            Prp2: binary.LittleEndian.Uint64(e, from: 32),
            Dword10: binary.LittleEndian.Uint32(e, from: 40),
            Dword11: binary.LittleEndian.Uint32(e, from: 44),
            Dword12: binary.LittleEndian.Uint32(e, from: 48),
            Dword13: binary.LittleEndian.Uint32(e, from: 52)
        )
    }
}

/// A completion queue in guest memory, with the phase bit that tells the
/// guest which entries are new.
public final class CompletionQueue {
    public let Id: int
    public let Vector: uint16
    /// Interrupts enabled (IEN): the queue raises the controller's INTx.
    public let Interrupts: bool
    let base: device.GuestAddress
    let size: uint16
    let memory: device.GuestMemory
    /// The guest's head, from its doorbell.
    public var Head: uint16 = 0
    var tail: uint16 = 0
    var phase: uint16 = 1

    init(id: int, base: device.GuestAddress, size: uint16, vector: uint16, interrupts: bool, memory: device.GuestMemory) {
        Id = id
        self.base = base
        self.size = size
        Vector = vector
        Interrupts = interrupts
        self.memory = memory
    }

    /// Entries posted that the guest hasn't consumed.
    var Pending: bool { tail != Head }

    var Full: bool { (tail + 1) % size == Head }

    func Post(command: uint16, sq: uint16, sqHead: uint16, status: uint16, result: uint32) throws {
        var e = [uint8](repeating: 0, count: 16)
        binary.LittleEndian.PutUint32(&e, result, at: 0)
        binary.LittleEndian.PutUint16(&e, sqHead, at: 8)
        binary.LittleEndian.PutUint16(&e, sq, at: 10)
        binary.LittleEndian.PutUint16(&e, command, at: 12)
        binary.LittleEndian.PutUint16(&e, (status << 1) | phase, at: 14)
        // The phase bit says the entry is new; the guest must see the data
        // and the rest of the entry before it.
        let at = base.Adding(uint64(tail) * 16)
        try memory.Write(at, Array(e[0..<14]))
        sync.MemoryFence()
        try memory.Write(at.Adding(14), Array(e[14..<16]))
        tail += 1
        if tail == size {
            tail = 0
            phase ^= 1
        }
    }
}

/// One contiguous piece of a transfer in guest memory.
public struct Segment {
    public let Address: device.GuestAddress
    public let Count: uint64
}

let pageSize: uint64 = 4096

/// Where a command's `count` bytes of data live: PRP1 (which may start
/// mid-page), then PRP2 as the second page or a PRP list. A list that
/// fills its page ends with a pointer to the next page of the list.
func prpSegments(_ cmd: Command, count: uint64, memory: device.GuestMemory) throws -> [Segment] {
    var out: [Segment] = []
    let first = min(count, pageSize - cmd.Prp1 % pageSize)
    out.append(Segment(Address: device.GuestAddress(cmd.Prp1), Count: first))
    var left = count - first
    if left == 0 {
        return out
    }
    if left <= pageSize {
        out.append(Segment(Address: device.GuestAddress(cmd.Prp2), Count: left))
        return out
    }
    var entry = cmd.Prp2
    while left > 0 {
        let p = try memory.Load64(device.GuestAddress(entry))
        // The last slot of a list page chains to the next page while
        // more than one page of data remains.
        if (entry + 8) % pageSize == 0 && left > pageSize {
            entry = p
            continue
        }
        let n = min(left, pageSize)
        out.append(Segment(Address: device.GuestAddress(p), Count: n))
        left -= n
        entry += 8
    }
    return out
}

/// Copies `bytes` into a command's data pages.
func scatter(_ bytes: borrowing [uint8], _ segs: [Segment], memory: device.GuestMemory) throws {
    var done = 0
    for s in segs {
        if done >= bytes.count { break }
        let n = min(int(s.Count), bytes.count - done)
        try memory.Write(s.Address, Array(bytes[done..<done + n]))
        done += n
    }
}

/// Reads a command's data pages into one buffer.
func gather(_ segs: [Segment], memory: device.GuestMemory) throws -> [uint8] {
    var out: [uint8] = []
    for s in segs {
        out.append(contentsOf: try memory.Read(s.Address, count: int(s.Count)))
    }
    return out
}
