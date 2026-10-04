package tpm

import (
    "encoding/binary"
    "sync"
    "vm/device"
)

// TIS registers, per locality (each locality has 4 KiB of its own).
let regAccess: uint64 = 0x00
let regIntEnable: uint64 = 0x08
let regIntVector: uint64 = 0x0c
let regIntStatus: uint64 = 0x10
let regIntfCapability: uint64 = 0x14
let regSts: uint64 = 0x18
let regDataFifo: uint64 = 0x24
let regInterfaceId: uint64 = 0x30
let regXDataFifo: uint64 = 0x80
let regXDataFifoEnd: uint64 = 0xbc
let regDidVid: uint64 = 0xf00
let regRid: uint64 = 0xf04

let stsFamily20: uint32 = 1 << 26
let stsResetEstablishment: uint32 = 1 << 25
let stsCommandCancel: uint32 = 1 << 24
let stsValid: uint32 = 1 << 7
let stsCommandReady: uint32 = 1 << 6
let stsGo: uint32 = 1 << 5
let stsDataAvailable: uint32 = 1 << 4
let stsExpect: uint32 = 1 << 3
let stsSelfTestDone: uint32 = 1 << 2
let stsResponseRetry: uint32 = 1 << 1

let accessRegValid: uint8 = 1 << 7
let accessActive: uint8 = 1 << 5
let accessBeenSeized: uint8 = 1 << 4
let accessSeize: uint8 = 1 << 3
let accessPending: uint8 = 1 << 2
let accessRequestUse: uint8 = 1 << 1
let accessEstablishment: uint8 = 1 << 0

let intEnabled: uint32 = 1 << 31
let intPolarityMask: uint32 = 3 << 3
let intPolarityLowLevel: uint32 = 1 << 3
let intsSupported: uint32 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 7)

let numLocalities = 5
let noLocality: int = 0xff
let bufferSize = 4096

enum State { case idle, ready, completion, execution, reception }

struct Locality {
    var access: uint8 = accessRegValid
    var sts: uint32 = stsFamily20
    var inte: uint32 = intPolarityLowLevel
    var ints: uint32 = 0
    var state = State.idle
    /// FIFO interface, 5 localities, TIS-compatible (TPM 2.0).
    var interfaceId: uint32 = (1 << 8) | (1 << 13)
}

/// A TPM's TIS / FIFO register interface over MMIO, 5 KiB per locality
/// times 5 (`Size`). Firmware and the OS find it by its device-tree node
/// (`tcg,tpm-tis-mmio`) or its ACPI device (MSFT0101) and TPM2 table, and
/// poll it: there is no interrupt.
///
/// The state machine is QEMU's (hw/tpm/tpm_tis_common.c): a locality is
/// requested and granted, the command is written into the FIFO, `tpmGo`
/// runs it on the backend in a task, and the guest polls `dataAvail` and
/// reads the response back out.
public final class Tis: device.Mmio {
    public static let Size: uint64 = 0x5000

    let backend: any Backend
    let lock = sync.Mutex()
    var loc: [Locality] = [Locality](repeating: Locality(), count: numLocalities)
    var activeLocality: int = noLocality
    var nextLocality: int = noLocality
    var abortingLocality: int = noLocality
    var buffer: [uint8] = [uint8](repeating: 0, count: 4096)   // bufferSize
    var offset = 0
    var failed = false
    /// Commands executed so far: how a test sees the guest using the TPM.
    public private(set) var CommandCount = 0

    public init(backend: any Backend) {
        self.backend = backend
    }

    func stsSet(_ l: int, _ flags: uint32) {
        loc[l].sts &= stsSelfTestDone | (3 << 26)
        loc[l].sts |= flags
    }

    // MARK: - Reading

    public func Read(offset addr: uint64, size: uint8) -> uint64 {
        lock.withLock { () -> uint64 in
            let l = int(addr >> 12) & 7
            if l >= numLocalities { return ~0 }
            let reg = addr & 0xffc
            let shift = (addr & 3) * 8
            var value: uint64 = 0xffff_ffff
            switch reg {
            case regAccess:
                var a = loc[l].access & ~accessSeize
                if requestUseExcept(l) { a |= accessPending }
                a |= accessEstablishment            // no DRTM: never established
                value = uint64(a)
            case regIntEnable:
                value = uint64(loc[l].inte)
            case regIntVector:
                value = 0
            case regIntStatus:
                value = uint64(loc[l].ints)
            case regIntfCapability:
                // Low-level interrupts, dynamic burst count, 64-byte
                // transfers, TIS 1.3 for TPM 2.0.
                value = uint64((1 << 4) | (3 << 9) | (3 << 28) | intsSupported)
            case regSts:
                if activeLocality == l {
                    var avail: int
                    if loc[l].sts & stsDataAvailable != 0 {
                        avail = min(wireSize(buffer), bufferSize) - offset
                    } else {
                        avail = bufferSize - offset
                        if size == 1 && avail > 0xff { avail = 0xff }
                    }
                    value = uint64((uint32(max(avail, 0)) & 0xffff) << 8 | loc[l].sts)
                }
            case regDataFifo, regXDataFifo...regXDataFifoEnd:
                if activeLocality == l {
                    let n = min(int(size), 4 - int(addr & 3))
                    var v: uint64 = 0
                    for i in 0..<n {
                        let b: uint8 = loc[l].state == .completion ? readByte(l) : 0xff
                        v |= uint64(b) << (8 * uint64(i))
                    }
                    return v
                }
            case regInterfaceId:
                value = uint64(loc[l].interfaceId)
            case regDidVid:
                value = (0x0001 << 16) | 0x1014           // QEMU's IDs: the TPM Windows and EDK2 already know
            case regRid:
                value = 0x0001
            default:
                break
            }
            return (value >> shift) & ((uint64(1) << (8 * uint64(size))) - 1)
        }
    }

    func readByte(_ l: int) -> uint8 {
        if loc[l].sts & stsDataAvailable == 0 { return 0xff }
        let len = min(wireSize(buffer), bufferSize)
        let b = buffer[offset]
        offset += 1
        if offset >= len {
            stsSet(l, stsValid)                         // got the last byte
        }
        return b
    }

    func requestUseExcept(_ l: int) -> bool {
        for i in 0..<numLocalities where i != l && loc[i].access & accessRequestUse != 0 {
            return true
        }
        return false
    }

    // MARK: - Writing

    public func Write(offset addr: uint64, size: uint8, value v: uint64) {
        lock.withLock {
            let l = int(addr >> 12) & 7
            if l >= 4 { return }                        // locality 4 is the hardware's
            let reg = addr & 0xffc
            let shift = (addr & 3) * 8
            let width: uint64 = size >= 4 ? 0xffff_ffff : (uint64(1) << (8 * uint64(size))) - 1
            let value = uint32(truncatingIfNeeded: (v & width) << shift)
            switch reg {
            case regAccess:
                writeAccess(l, uint8(truncatingIfNeeded: value))
            case regIntEnable:
                let mask = uint32(truncatingIfNeeded: ~(width << shift))
                loc[l].inte = (loc[l].inte & mask) | (value & (intEnabled | intPolarityMask | intsSupported))
            case regIntStatus:
                loc[l].ints &= ~(value & intsSupported)
            case regSts:
                writeSts(l, value)
            case regDataFifo, regXDataFifo...regXDataFifoEnd:
                writeFifo(l, uint64(value) >> shift, min(int(size), 4 - int(addr & 3)))
            case regInterfaceId:
                if value & (1 << 19) != 0 {
                    for i in 0..<numLocalities { loc[i].interfaceId |= 1 << 19 }
                }
            default:
                break
            }
        }
    }

    func writeAccess(_ l: int, _ v0: uint8) {
        var v = v0
        var setNew = true
        if v & accessSeize != 0 {
            v &= ~(accessRequestUse | accessActive)
        }
        var active = activeLocality
        if v & accessActive != 0 {
            if activeLocality == l {
                // Giving the locality up: anybody waiting gets it.
                var next = noLocality
                var c = numLocalities - 1
                while c >= 0 {
                    if loc[c].access & accessRequestUse != 0 { next = c; break }
                    c -= 1
                }
                if next != noLocality {
                    setNew = false
                    prepareAbort(l, next)
                } else {
                    active = noLocality
                }
            } else {
                loc[l].access &= ~accessRequestUse
            }
        }
        if v & accessBeenSeized != 0 {
            loc[l].access &= ~accessBeenSeized
        }
        if v & accessSeize != 0 {
            if (activeLocality != noLocality && l > activeLocality) || activeLocality == noLocality {
                var higher = false
                for h in (l + 1)..<numLocalities where loc[h].access & accessSeize != 0 { higher = true }
                if loc[l].access & accessSeize == 0 && !higher {
                    for lower in 0..<l { loc[lower].access &= ~accessSeize }
                    loc[l].access |= accessSeize
                    setNew = false
                    prepareAbort(activeLocality, l)
                }
            }
        }
        if v & accessRequestUse != 0 && activeLocality != l {
            if activeLocality != noLocality {
                loc[l].access |= accessRequestUse
            } else {
                active = l
            }
        }
        if setNew {
            newActiveLocality(active)
        }
    }

    func newActiveLocality(_ new: int) {
        let change = activeLocality != new
        if change && activeLocality != noLocality {
            let seize = new != noLocality && loc[new].access & accessSeize != 0
            let mask: uint8 = seize ? ~accessActive : ~(accessActive | accessRequestUse)
            loc[activeLocality].access &= mask
            if seize { loc[activeLocality].access |= accessBeenSeized }
        }
        activeLocality = new
        if new != noLocality {
            loc[new].access |= accessActive
            loc[new].access &= ~(accessRequestUse | accessSeize)
        }
    }

    func prepareAbort(_ aborting: int, _ next: int) {
        abortingLocality = aborting
        nextLocality = next
        // A command running now finishes first; its completion aborts.
        for i in 0..<numLocalities where loc[i].state == .execution {
            return
        }
        abort()
    }

    func abort() {
        offset = 0
        if abortingLocality == nextLocality && abortingLocality != noLocality {
            loc[abortingLocality].state = .ready
            stsSet(abortingLocality, stsCommandReady)
        }
        newActiveLocality(nextLocality)
        nextLocality = noLocality
        abortingLocality = noLocality
    }

    func writeSts(_ l: int, _ value: uint32) {
        if activeLocality != l { return }
        let v = value & (stsCommandReady | stsGo | stsResponseRetry)
        if v == stsCommandReady {
            switch loc[l].state {
            case .ready:
                offset = 0
            case .idle:
                stsSet(l, stsCommandReady)
                loc[l].state = .ready
            case .execution, .reception:
                prepareAbort(l, l)
            case .completion:
                offset = 0
                loc[l].state = .ready
                if loc[l].sts & stsCommandReady == 0 {
                    stsSet(l, stsCommandReady)
                }
                loc[l].sts &= ~stsDataAvailable
            }
        } else if v == stsGo {
            if loc[l].state == .reception && loc[l].sts & stsExpect == 0 {
                send(l)
            }
        } else if v == stsResponseRetry {
            if loc[l].state == .completion {
                offset = 0
                stsSet(l, stsValid | stsDataAvailable)
            }
        }
    }

    func writeFifo(_ l: int, _ value: uint64, _ count: int) {
        if activeLocality != l { return }
        let s = loc[l].state
        if s == .idle || s == .execution || s == .completion {
            return                                      // dropped
        }
        if s == .ready {
            loc[l].state = .reception
            stsSet(l, stsExpect | stsValid)
        }
        var v = value
        var n = count
        while loc[l].sts & stsExpect != 0 && n > 0 {
            if offset < bufferSize {
                buffer[offset] = uint8(truncatingIfNeeded: v)
                offset += 1
                v >>= 8
                n -= 1
            } else {
                stsSet(l, stsValid)
                break
            }
        }
        // With the header in, the size says whether the command is whole.
        if offset > 5 && loc[l].sts & stsExpect != 0 {
            if wireSize(buffer) > offset {
                stsSet(l, stsExpect | stsValid)
            } else {
                stsSet(l, stsValid)
            }
        }
    }

    /// tpmGo: the command goes to the backend; the guest polls for its
    /// answer.
    func send(_ l: int) {
        loc[l].state = .execution
        CommandCount += 1
        let command = Array(buffer[0..<min(offset, bufferSize)])
        let backend = self.backend
        let wasFailed = failed
        Task {
            var response: [uint8]
            if wasFailed {
                response = FailureResponse()
            } else {
                do {
                    response = try await backend.Execute(command, locality: uint8(l))
                } catch {
                    print("[tpm] \(error); the guest sees a failed TPM")
                    self.lock.withLock { self.failed = true }
                    response = FailureResponse()
                }
            }
            self.completed(l, response)
        }
    }

    func completed(_ l: int, _ response: [uint8]) {
        lock.withLock {
            let n = min(response.count, bufferSize)
            for i in 0..<n { buffer[i] = response[i] }
            // TPM2_SelfTest and friends: a response at all means it ran.
            for i in 0..<numLocalities { loc[i].sts |= stsSelfTestDone }
            stsSet(l, stsValid | stsDataAvailable)
            loc[l].state = .completion
            offset = 0
            if nextLocality != noLocality {
                abort()
            }
        }
    }

    /// Powers the TPM on: the machine is starting. Firmware sends
    /// TPM2_Startup itself.
    public func PowerOn() async throws {
        try await backend.Init()
    }

    public func Shutdown() {
        backend.Shutdown()
    }
}
