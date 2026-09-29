package nvme

import "vm/device"

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
            Id: LE.Uint16(e, from: 2),
            Namespace: LE.Uint32(e, from: 4),
            Prp1: LE.Uint64(e, from: 24),
            Prp2: LE.Uint64(e, from: 32),
            Dword10: LE.Uint32(e, from: 40),
            Dword11: LE.Uint32(e, from: 44),
            Dword12: LE.Uint32(e, from: 48)
        )
    }
}

/// A completion queue in guest memory, with the phase bit that tells the
/// guest which entries are new.
public final class CompletionQueue {
    public let Id: int
    public let Vector: uint16
    let base: device.GuestAddress
    let size: uint16
    let memory: device.GuestMemory
    public var Head: uint16 = 0
    var tail: uint16 = 0
    var phase: uint16 = 1

    init(id: int, base: device.GuestAddress, size: uint16, vector: uint16, memory: device.GuestMemory) {
        Id = id
        self.base = base
        self.size = size
        Vector = vector
        self.memory = memory
    }

    func Post(command: uint16, sq: uint16, sqHead: uint16, status: uint16, result: uint32) throws {
        var e = [uint8](repeating: 0, count: 16)
        LE.PutUint32(&e, result, at: 0)
        LE.PutUint16(&e, sqHead, at: 8)
        LE.PutUint16(&e, sq, at: 10)
        LE.PutUint16(&e, command, at: 12)
        LE.PutUint16(&e, (status << 1) | phase, at: 14)
        try memory.Write(base.Adding(uint64(tail) * 16), e)
        tail += 1
        if tail == size {
            tail = 0
            phase ^= 1
        }
    }
}

/// The guest pages a command's data lives in: PRP1, then PRP2 as a
/// second page or a PRP list.
func prpPages(_ cmd: Command, count: uint64, memory: device.GuestMemory) throws -> [device.GuestAddress] {
    let page: uint64 = 4096
    var pages = [device.GuestAddress(cmd.Prp1)]
    let first = page - cmd.Prp1 % page
    if count <= first {
        return pages
    }
    let remaining = (count - first + page - 1) / page
    if remaining == 1 {
        pages.append(device.GuestAddress(cmd.Prp2))
        return pages
    }
    // TODO(P4): PRP lists that chain across pages.
    var list = device.GuestAddress(cmd.Prp2)
    for _ in 0..<remaining {
        pages.append(device.GuestAddress(try memory.Load64(list)))
        list = list.Adding(8)
    }
    return pages
}
