// Package nvme is an NVMe controller over PCI: the disk that Windows
// (stornvme), Linux, the BSDs and UEFI (NvmExpressDxe) all drive with
// their own inbox drivers. It's the standard profile's default disk for
// Windows guests, and an option for everyone else.
//
// Interrupts are MSI-X where the platform gives it an MSI path (on arm64,
// the GIC's MSI frame): a message per completion, to its queue's vector.
// Otherwise PCI INTx, level-triggered: the line is up while any completion
// queue with interrupts enabled holds entries the guest hasn't consumed.
package nvme

import (
    "encoding/binary"
    "sync"
    "vm/device"
    "vm/disk"
    "vm/pci"
)


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
    public private(set) var Namespaces: [Namespace] = []

    var cc: uint32 = 0
    var csts: uint32 = 0
    var aqa: uint32 = 0
    var asq: uint64 = 0
    var acq: uint64 = 0
    var intms: uint32 = 0
    var submission: [int: SubmissionQueue] = [:]
    var completion: [int: CompletionQueue] = [:]
    var features: [uint32: uint32] = [:]
    /// Prints register writes, doorbells, commands and INTx changes.
    public var Trace = false
    var lastLevel = false

    /// MSI-X, where the platform can deliver MSIs: a vector per queue.
    let msix: pci.MsixTable?

    /// `msi` delivers MSI-X writes; nil leaves the controller on INTx.
    public init(memory: device.GuestMemory, msi: (any device.Msi)? = nil, serial: string = "VERTEX0001") {
        self.memory = memory
        Serial = serial
        Config = pci.ConfigSpace(vendor: 0x1b36, device: 0x0010, classCode: .nvme, revision: 2,
                                 subsystemVendor: 0x1af4, subsystem: 0x1100)
        Config.AddPcieCapability()
        if let m = msi {
            let table = pci.MsixTable(vectors: MaxQueues + 1, msi: m)
            Config.AddMsixCapability(table, bar: 0, tableOffset: 0x2000, pbaOffset: 0x3000)
            msix = table
        } else {
            msix = nil
        }
    }

    /// Adds a namespace (NSID = its position + 1) backed by an image.
    @discardableResult
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
        c |= uint64(1023)              // MQES: 1024 entries
        c |= 1 << 16                   // CQR: contiguous queues required
        c |= uint64(20) << 24          // TO: 10 s ready timeout, in 500 ms units
        c |= 1 << 37                   // CSS: NVM command set
        return c                       // DSTRD 0, MPSMIN = MPSMAX = 4 KiB
    }

    public func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64 {
        if let t = msix, offset >= 0x2000 {
            return offset < 0x3000 ? t.ReadTable(offset: offset - 0x2000, size: size) : t.ReadPba(offset: offset - 0x3000, size: size)
        }
        return lock.withLock {
            switch offset {
            case regCap: return size == 8 ? capabilities : capabilities & 0xffff_ffff
            case regCap + 4: return capabilities >> 32
            case regVs: return 0x0001_0400        // 1.4
            case regIntms, regIntmc: return uint64(intms)
            case regCc: return uint64(cc)
            case regCsts: return uint64(csts)
            case regAqa: return uint64(aqa)
            case regAsq: return size == 8 ? asq : asq & 0xffff_ffff
            case regAsq + 4: return asq >> 32
            case regAcq: return size == 8 ? acq : acq & 0xffff_ffff
            case regAcq + 4: return acq >> 32
            default: return 0
            }
        }
    }

    public func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64) {
        if Trace { print("[nvme] write 0x\(string(offset, radix: 16)) = 0x\(string(value, radix: 16))") }
        if offset >= 0x2000 {
            if let t = msix, offset < 0x3000 {
                t.WriteTable(offset: offset - 0x2000, size: size, value: value)
            }
            return
        }
        if offset >= doorbellBase {
            doorbell(offset - doorbellBase, uint32(truncatingIfNeeded: value))
            return
        }
        lock.withLock {
            switch offset {
            case regIntms: intms |= uint32(truncatingIfNeeded: value)
            case regIntmc: intms &= ~uint32(truncatingIfNeeded: value)
            case regCc: writeCc(uint32(truncatingIfNeeded: value))
            case regAqa: aqa = uint32(truncatingIfNeeded: value)
            case regAsq: asq = size == 8 ? value : (asq & 0xffff_ffff_0000_0000) | (value & 0xffff_ffff)
            case regAsq + 4: asq = (asq & 0xffff_ffff) | (value << 32)
            case regAcq: acq = size == 8 ? value : (acq & 0xffff_ffff_0000_0000) | (value & 0xffff_ffff)
            case regAcq + 4: acq = (acq & 0xffff_ffff) | (value << 32)
            default: break
            }
        }
        updateIntx()
    }

    func writeCc(_ v: uint32) {
        let wasEnabled = cc & 1 != 0
        cc = v
        if v & 1 != 0 && !wasEnabled {
            let sqSize = uint16((aqa & 0xfff) + 1)
            let cqSize = uint16(((aqa >> 16) & 0xfff) + 1)
            completion[0] = CompletionQueue(id: 0, base: device.GuestAddress(acq), size: cqSize, vector: 0,
                                            interrupts: true, memory: memory)
            submission[0] = SubmissionQueue(id: 0, base: device.GuestAddress(asq), size: sqSize, cq: 0, memory: memory)
            csts = 1                          // RDY
        } else if v & 1 == 0 && wasEnabled {
            // A reset: every queue goes, and the controller is idle.
            submission = [:]
            completion = [:]
            features = [:]
            intms = 0
            csts = 0
        }
        if (v >> 14) & 3 != 0 {
            csts = (csts & ~0xc) | (2 << 2)   // shutdown processing complete
        } else {
            csts &= ~0xc
        }
    }

    /// The INTx level: some queue with interrupts on has entries the
    /// guest hasn't taken, and the guest hasn't masked them (INTMS bit 0).
    ///
    /// The line is driven under the controller's lock: a level worked out
    /// by one thread and set after another's would stick, and a
    /// level-triggered line held up with nothing pending is an interrupt
    /// storm.
    func updateIntx() {
        lock.withLock {
            var level = false
            if intms & 1 == 0 {
                for (_, cq) in completion where cq.Interrupts && cq.Pending {
                    level = true
                }
            }
            if Trace && level != lastLevel { print("[nvme] INTx \(level)") }
            lastLevel = level
            Config.SetIntx(level)
        }
    }

    // Doorbells: SQ y tail at 0x1000 + (2y) * 4, CQ y head at 0x1000 + (2y+1) * 4.
    func doorbell(_ offset: uint64, _ value: uint32) {
        let index = int(offset / 4)
        let qid = index / 2
        if index % 2 == 1 {
            lock.withLock { completion[qid]?.Head = uint16(truncatingIfNeeded: value) }
            updateIntx()
            // A full queue may have left commands waiting for room.
            kickAll()
            return
        }
        let start = lock.withLock { () -> SubmissionQueue? in
            guard let sq = submission[qid] else { return nil }
            sq.Tail = uint16(truncatingIfNeeded: value)
            if sq.draining { return nil }
            sq.draining = true
            return sq
        }
        if let sq = start {
            run(sq)
        }
    }

    /// Takes `sq`'s commands. The admin queue is answered here, on the
    /// thread that rang its doorbell, before the write returns: drivers
    /// poll admin completions while they start the controller (stornvme
    /// does, with its interrupt unmasked and its ISR declining), and a
    /// completion that lands after the poll looked but before it ends
    /// leaves INTx up with nobody to take it. I/O queues go to a task,
    /// since they wait on the disk.
    func run(_ sq: SubmissionQueue) {
        if sq.Id == 0 {
            while let cmd = next(sq) {
                if cmd.Opcode == 0x0c { continue }   // AER: no events to report
                let (status, result) = admin(cmd)
                post(sq, cmd, status, result)
            }
            return
        }
        Task {
            await self.drain(sq)
        }
    }

    func kickAll() {
        let idle = lock.withLock { () -> [SubmissionQueue] in
            var out: [SubmissionQueue] = []
            for (_, sq) in submission where !sq.draining && sq.Head != sq.Tail {
                sq.draining = true
                out.append(sq)
            }
            return out
        }
        for sq in idle {
            run(sq)
        }
    }

    /// The next command on `sq`, or nil, clearing its draining flag, when
    /// it is empty or its completion queue is full (the guest frees room
    /// with its head doorbell, which runs the queue again).
    func next(_ sq: SubmissionQueue) -> Command? {
        lock.withLock { () -> Command? in
            if let cq = completion[sq.CompletionQueue], cq.Full {
                sq.draining = false
                return nil
            }
            guard let cmd = try? sq.Pop() else {
                sq.draining = false
                return nil
            }
            return cmd
        }
    }

    func post(_ sq: SubmissionQueue, _ cmd: Command, _ status: uint16, _ result: uint32) {
        let vector = lock.withLock { () -> int? in
            if Trace { print("[nvme] sq \(sq.Id) cid \(cmd.Id) op 0x\(string(cmd.Opcode, radix: 16)) -> 0x\(string(status, radix: 16)) cq \(sq.CompletionQueue)") }
            guard let cq = completion[sq.CompletionQueue] else { return nil }
            try? cq.Post(command: cmd.Id, sq: uint16(sq.Id), sqHead: sq.Head, status: status, result: result)
            return cq.Interrupts ? int(cq.Vector) : nil
        }
        // MSI-X: a message per completion, to the queue's vector. INTx: a
        // level, held while anything is unread.
        if let t = msix, Config.MsixEnabled {
            if let v = vector { t.Signal(v) }
        } else {
            updateIntx()
        }
    }

    /// Runs an I/O queue's commands until it is empty, one at a time. Only
    /// one task drains a queue at once.
    func drain(_ sq: SubmissionQueue) async {
        while let cmd = next(sq) {
            let (status, result) = await io(cmd)
            post(sq, cmd, status, result)
        }
    }

    func admin(_ cmd: Command) -> (uint16, uint32) {
        switch cmd.Opcode {
        case 0x00: return deleteSq(cmd)
        case 0x01: return createSq(cmd)
        case 0x02: return logPage(cmd)
        case 0x04: return deleteCq(cmd)
        case 0x05: return createCq(cmd)
        case 0x06: return identify(cmd)
        case 0x08: return (Status.success, 1)         // Abort: the command wasn't aborted
        case 0x09: return setFeatures(cmd)
        case 0x0a: return getFeatures(cmd)
        case 0x18: return (Status.success, 0)         // Keep Alive
        default: return (Status.invalidOpcode, 0)
        }
    }

    func createCq(_ cmd: Command) -> (uint16, uint32) {
        let qid = int(cmd.Dword10 & 0xffff)
        let size = uint16(truncatingIfNeeded: (cmd.Dword10 >> 16) + 1)
        return lock.withLock { () -> (uint16, uint32) in
            if qid == 0 || qid > MaxQueues || completion[qid] != nil { return (Status.invalidQueueId, 0) }
            if size < 2 || uint64(size) > (capabilities & 0xffff) + 1 { return (Status.invalidQueueSize, 0) }
            if cmd.Dword11 & 1 == 0 { return (Status.invalidField, 0) }   // CQR: contiguous only
            completion[qid] = CompletionQueue(id: qid, base: device.GuestAddress(cmd.Prp1), size: size,
                                              vector: uint16(cmd.Dword11 >> 16), interrupts: cmd.Dword11 & 2 != 0,
                                              memory: memory)
            return (Status.success, 0)
        }
    }

    func createSq(_ cmd: Command) -> (uint16, uint32) {
        let qid = int(cmd.Dword10 & 0xffff)
        let size = uint16(truncatingIfNeeded: (cmd.Dword10 >> 16) + 1)
        let cqid = int(cmd.Dword11 >> 16)
        return lock.withLock { () -> (uint16, uint32) in
            if qid == 0 || qid > MaxQueues || submission[qid] != nil { return (Status.invalidQueueId, 0) }
            if size < 2 || uint64(size) > (capabilities & 0xffff) + 1 { return (Status.invalidQueueSize, 0) }
            if cqid == 0 || completion[cqid] == nil { return (Status.completionQueueInvalid, 0) }
            if cmd.Dword11 & 1 == 0 { return (Status.invalidField, 0) }
            submission[qid] = SubmissionQueue(id: qid, base: device.GuestAddress(cmd.Prp1), size: size, cq: cqid, memory: memory)
            return (Status.success, 0)
        }
    }

    func deleteSq(_ cmd: Command) -> (uint16, uint32) {
        let qid = int(cmd.Dword10 & 0xffff)
        return lock.withLock { () -> (uint16, uint32) in
            if qid == 0 || submission[qid] == nil { return (Status.invalidQueueId, 0) }
            submission[qid] = nil
            return (Status.success, 0)
        }
    }

    func deleteCq(_ cmd: Command) -> (uint16, uint32) {
        let qid = int(cmd.Dword10 & 0xffff)
        let (status, result) = lock.withLock { () -> (uint16, uint32) in
            if qid == 0 || completion[qid] == nil { return (Status.invalidQueueId, 0) }
            for (_, sq) in submission where sq.CompletionQueue == qid {
                return (Status.invalidQueueDeletion, 0)
            }
            completion[qid] = nil
            return (Status.success, 0)
        }
        updateIntx()
        return (status, result)
    }

    func setFeatures(_ cmd: Command) -> (uint16, uint32) {
        let fid = cmd.Dword10 & 0xff
        switch fid {
        case 0x07:
            // Number of Queues: as many as asked for, up to MaxQueues.
            let n = uint32(MaxQueues - 1)
            return (Status.success, n | (n << 16))
        case 0x01, 0x02, 0x04, 0x05, 0x08, 0x09, 0x0a, 0x0b:
            lock.withLock { features[fid] = cmd.Dword11 }
            return (Status.success, 0)
        default:
            return (Status.invalidField, 0)   // includes 0x06: no volatile write cache
        }
    }

    func getFeatures(_ cmd: Command) -> (uint16, uint32) {
        let fid = cmd.Dword10 & 0xff
        switch fid {
        case 0x07:
            let n = uint32(MaxQueues - 1)
            return (Status.success, n | (n << 16))
        case 0x04:
            return (Status.success, lock.withLock { features[fid] } ?? 0x0157)   // temperature threshold
        case 0x01, 0x02, 0x05, 0x08, 0x09, 0x0a, 0x0b:
            return (Status.success, lock.withLock { features[fid] } ?? 0)
        default:
            return (Status.invalidField, 0)
        }
    }

    func logPage(_ cmd: Command) -> (uint16, uint32) {
        let lid = cmd.Dword10 & 0xff
        let dwords = uint64((cmd.Dword10 >> 16) | ((cmd.Dword11 & 0xffff) << 16)) + 1
        var page = [uint8](repeating: 0, count: 4096)
        switch lid {
        case 0x01:   // error information: none
            break
        case 0x02:   // SMART / health: 321 K, all spare left
            page[1] = 0x41; page[2] = 0x01
            page[3] = 100
            page[4] = 10
        case 0x03:   // firmware slot: slot 1 active
            page[0] = 1
            let fr = Array("1.0     ".utf8)
            for i in 0..<8 { page[8 + i] = fr[i] }
        default:
            return (Status.invalidLogPage, 0)
        }
        let count = min(dwords * 4, uint64(page.count))
        do {
            let segs = try prpSegments(cmd, count: count, memory: memory)
            try scatter(Array(page[0..<int(count)]), segs, memory: memory)
            return (Status.success, 0)
        } catch {
            return (Status.dataTransferError, 0)
        }
    }

    func identify(_ cmd: Command) -> (uint16, uint32) {
        let cns = cmd.Dword10 & 0xff
        var data: [uint8]
        switch cns {
        case 0x00:
            guard cmd.Namespace >= 1, int(cmd.Namespace) <= Namespaces.count else {
                return (Status.invalidNamespace, 0)
            }
            data = Namespaces[int(cmd.Namespace) - 1].Identify()
        case 0x01:
            data = identifyController()
        case 0x02:
            // Active namespace IDs greater than NSID, ascending.
            data = [uint8](repeating: 0, count: 4096)
            var at = 0
            for ns in Namespaces where ns.Id > cmd.Namespace {
                binary.LittleEndian.PutUint32(&data, ns.Id, at: at)
                at += 4
            }
        case 0x03:
            // Namespace identification descriptors: none beyond the NSID.
            guard cmd.Namespace >= 1, int(cmd.Namespace) <= Namespaces.count else {
                return (Status.invalidNamespace, 0)
            }
            data = [uint8](repeating: 0, count: 4096)
        default:
            return (Status.invalidField, 0)
        }
        do {
            let segs = try prpSegments(cmd, count: 4096, memory: memory)
            try scatter(data, segs, memory: memory)
            return (Status.success, 0)
        } catch {
            return (Status.dataTransferError, 0)
        }
    }

    func identifyController() -> [uint8] {
        var b = [uint8](repeating: 0, count: 4096)
        binary.LittleEndian.PutUint16(&b, 0x1b36, at: 0)                 // VID
        binary.LittleEndian.PutUint16(&b, 0x1af4, at: 2)                 // SSVID
        putAscii(&b, at: 4, count: 20, Serial)          // SN
        putAscii(&b, at: 24, count: 40, "Vertex NVMe Disk")   // MN
        putAscii(&b, at: 64, count: 8, "1.0")           // FR
        b[72] = 6                                       // RAB
        b[77] = 7                                       // MDTS: 2^7 pages = 512 KiB
        binary.LittleEndian.PutUint32(&b, 0x0001_0400, at: 80)           // VER 1.4
        b[111] = 1                                      // CNTRLTYPE: I/O controller
        b[258] = 3                                      // ACL
        b[259] = 3                                      // AERL
        b[260] = 0x03                                   // FRMW: one slot, read-only
        binary.LittleEndian.PutUint16(&b, 0x0157, at: 266)               // WCTEMP
        binary.LittleEndian.PutUint16(&b, 0x0175, at: 268)               // CCTEMP
        b[512] = 0x66                                   // SQES: 64 bytes
        b[513] = 0x44                                   // CQES: 16 bytes
        binary.LittleEndian.PutUint32(&b, uint32(Namespaces.count), at: 516)   // NN
        binary.LittleEndian.PutUint16(&b, 0x000c, at: 520)               // ONCS: dataset management, write zeroes
        b[525] = 0                                      // VWC: none
        binary.LittleEndian.PutUint16(&b, 2500, at: 2048)                // power state 0: 25 W
        return b
    }

    func io(_ cmd: Command) async -> (uint16, uint32) {
        guard cmd.Namespace >= 1, int(cmd.Namespace) <= Namespaces.count else {
            return (Status.invalidNamespace, 0)
        }
        return await Namespaces[int(cmd.Namespace) - 1].Execute(cmd, memory: memory)
    }
}

func putAscii(_ b: inout [uint8], at: int, count: int, _ s: string) {
    let bytes = Array(s.utf8)
    for i in 0..<count {
        b[at + i] = i < bytes.count ? bytes[i] : 0x20
    }
}

/// Completion status: status code type << 8 | status code.
public enum Status {
    public static let success: uint16 = 0x0
    public static let invalidOpcode: uint16 = 0x1
    public static let invalidField: uint16 = 0x2
    public static let dataTransferError: uint16 = 0x4
    public static let invalidNamespace: uint16 = 0xb
    public static let writeProtected: uint16 = 0x20
    public static let lbaOutOfRange: uint16 = 0x80
    public static let completionQueueInvalid: uint16 = 0x100
    public static let invalidQueueId: uint16 = 0x101
    public static let invalidQueueSize: uint16 = 0x102
    public static let invalidLogPage: uint16 = 0x109
    public static let invalidQueueDeletion: uint16 = 0x10c
}
