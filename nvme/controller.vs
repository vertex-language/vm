// Package nvme is an NVMe controller over PCI: the disk that Windows
// (stornvme), Linux, the BSDs and UEFI (NvmExpressDxe) all drive with
// their own inbox drivers. It's the standard profile's default disk for
// Windows guests, and an option for everyone else.
package nvme

import (
    "encoding/binary"
    "sync"
    "vm/device"
    "vm/disk"
    "vm/pci"
)

typealias LE = binary.LittleEndian

// Controller registers (NVMe 1.4 §3.1), in BAR 0.
let regCap: uint64 = 0x00
let regVs: uint64 = 0x08
let regIntms: uint64 = 0x0c
let regIntmc: uint64 = 0x10
let regCc: uint64 = 0x14
let regCsts: uint64 = 0x1c
let regAqa: uint64 = 0x24
let regAsq: uint64 = 0x28
let regAcq: uint64 = 0x30
let doorbellBase: uint64 = 0x1000

/// An NVMe controller: one PCI function, one admin queue pair, up to
/// `MaxQueues` I/O queue pairs, and a namespace per disk image.
public final class Controller: pci.Function {
    public let Config: pci.ConfigSpace
    public let MaxQueues = 16
    public let Serial: string
    let memory: device.GuestMemory
    let lock = sync.Mutex()
    var msix: pci.MsixTable
    public private(set) var Namespaces: [Namespace] = []

    var cc: uint32 = 0
    var csts: uint32 = 0
    var aqa: uint32 = 0
    var asq: uint64 = 0
    var acq: uint64 = 0
    var submission: [int: SubmissionQueue] = [:]
    var completion: [int: CompletionQueue] = [:]

    public init(memory: device.GuestMemory, msi: any device.Msi, serial: string = "VERTEX0001") {
        self.memory = memory
        Serial = serial
        msix = pci.MsixTable(vectors: 17, msi: msi)
        Config = pci.ConfigSpace(vendor: 0x1b36, device: 0x0010, classCode: .nvme, revision: 2)
        // TODO(P4): MSI-X capability pointing at BAR 0 + 0x2000 (table) / 0x3000 (PBA),
        // and a PCI Express capability (Windows' stornvme requires one).
    }

    /// Adds a namespace (NSID = its position + 1) backed by an image.
    public func Attach(_ image: any disk.Image) -> Namespace {
        let ns = Namespace(id: uint32(Namespaces.count + 1), image: image)
        Namespaces.append(ns)
        return ns
    }

    public var Bars: [pci.Bar] {
        [pci.Bar(index: 0, size: 0x4000, kind: .memory64, prefetchable: false)]
    }

    var capabilities: uint64 {
        var c: uint64 = 0
        c |= uint64(4095)              // MQES: 4096 entries
        c |= 1 << 16                   // CQR: contiguous queues required
        c |= uint64(20) << 24          // TO: 10 s ready timeout, in 500 ms units
        c |= 1 << 37                   // CSS: NVM command set
        return c
    }

    public func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64 {
        if offset >= 0x2000 && offset < 0x3000 {
            return msix.ReadTable(offset: offset - 0x2000, size: size)
        }
        if offset >= 0x3000 {
            return msix.ReadPba(offset: offset - 0x3000, size: size)
        }
        return lock.withLock {
            switch offset {
            case regCap: return size == 8 ? capabilities : capabilities & 0xffff_ffff
            case regCap + 4: return capabilities >> 32
            case regVs: return 0x0001_0400        // 1.4
            case regCc: return uint64(cc)
            case regCsts: return uint64(csts)
            case regAqa: return uint64(aqa)
            case regAsq: return asq
            case regAcq: return acq
            default: return 0
            }
        }
    }

    public func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64) {
        if offset >= 0x2000 && offset < 0x3000 {
            msix.WriteTable(offset: offset - 0x2000, size: size, value: value)
            return
        }
        if offset >= doorbellBase {
            doorbell(offset - doorbellBase, uint32(truncatingIfNeeded: value))
            return
        }
        lock.withLock {
            switch offset {
            case regCc: writeCc(uint32(truncatingIfNeeded: value))
            case regAqa: aqa = uint32(truncatingIfNeeded: value)
            case regAsq: asq = size == 8 ? value : (asq & 0xffff_ffff_0000_0000) | value
            case regAsq + 4: asq = (asq & 0xffff_ffff) | (value << 32)
            case regAcq: acq = size == 8 ? value : (acq & 0xffff_ffff_0000_0000) | value
            case regAcq + 4: acq = (acq & 0xffff_ffff) | (value << 32)
            default: break
            }
        }
    }

    func writeCc(_ v: uint32) {
        let wasEnabled = cc & 1 != 0
        cc = v
        if v & 1 != 0 && !wasEnabled {
            let sqSize = uint16((aqa & 0xfff) + 1)
            let cqSize = uint16(((aqa >> 16) & 0xfff) + 1)
            completion[0] = CompletionQueue(id: 0, base: device.GuestAddress(acq), size: cqSize, vector: 0, memory: memory)
            submission[0] = SubmissionQueue(id: 0, base: device.GuestAddress(asq), size: sqSize, cq: 0, memory: memory)
            csts |= 1                         // RDY
        } else if v & 1 == 0 && wasEnabled {
            submission.removeAll()
            completion.removeAll()
            csts &= ~1
        }
        if (v >> 14) & 3 != 0 {
            csts = (csts & ~0xc) | (2 << 2)   // shutdown processing complete
        }
    }

    // Doorbells: SQ y tail at 0x1000 + (2y) * 4, CQ y head at 0x1000 + (2y+1) * 4.
    func doorbell(_ offset: uint64, _ value: uint32) {
        let index = int(offset / 4)
        let qid = index / 2
        if index % 2 == 1 {
            lock.withLock { completion[qid]?.Head = uint16(value) }
            return
        }
        guard let sq = lock.withLock({ submission[qid] }) else { return }
        sq.Tail = uint16(value)
        Task {
            await self.drain(sq)
        }
    }

    func drain(_ sq: SubmissionQueue) async {
        while let cmd = try? sq.Pop() {
            let status: uint16
            let result: uint32
            if sq.Id == 0 {
                (status, result) = admin(cmd)
            } else {
                (status, result) = await io(cmd)
            }
            guard let cq = lock.withLock({ completion[int(sq.CompletionQueue)] }) else { continue }
            try? cq.Post(command: cmd.Id, sq: uint16(sq.Id), sqHead: sq.Head, status: status, result: result)
            msix.Signal(int(cq.Vector))
        }
    }

    func admin(_ cmd: Command) -> (uint16, uint32) {
        switch cmd.Opcode {
        case 0x06: return identify(cmd)
        case 0x05, 0x01, 0x04, 0x00:
            // TODO(P4): create I/O CQ (0x05) / SQ (0x01), delete (0x04 / 0x00).
            return (Status.success, 0)
        case 0x09, 0x0a:
            // Set / Get Features: Number of Queues answers (MaxQueues-1) in both halves.
            if cmd.Dword10 & 0xff == 0x07 {
                let n = uint32(MaxQueues - 1)
                return (Status.success, n | (n << 16))
            }
            return (Status.success, 0)
        default:
            return (Status.invalidOpcode, 0)
        }
    }

    func identify(_ cmd: Command) -> (uint16, uint32) {
        // TODO(P4): CNS 1 controller (VID, SN, MN, FR, MDTS, SQES/CQES, NN),
        // CNS 0 namespace (NSZE, NCAP, NUSE, LBAF0 = 512 B), CNS 2 active list,
        // written to cmd.Prp1 (4 KiB).
        return (Status.success, 0)
    }

    func io(_ cmd: Command) async -> (uint16, uint32) {
        guard cmd.Namespace >= 1, int(cmd.Namespace) <= Namespaces.count else {
            return (Status.invalidNamespace, 0)
        }
        return await Namespaces[int(cmd.Namespace) - 1].Execute(cmd, memory: memory)
    }
}

/// Completion status codes (generic command status, SCT 0).
public enum Status {
    public static let success: uint16 = 0x0
    public static let invalidOpcode: uint16 = 0x1
    public static let invalidField: uint16 = 0x2
    public static let dataTransferError: uint16 = 0x4
    public static let invalidNamespace: uint16 = 0xb
    public static let lbaOutOfRange: uint16 = 0x80
}
