package vm

import (
    "vm/device"
    "vm/hypervisor"
)

/// The translation state of an arm64 vCPU: enough to walk its page tables
/// from the host when a guest hangs or faults.
public struct Arm64Mmu {
    public var Sctlr: uint64 = 0
    public var Tcr: uint64 = 0
    public var Ttbr0: uint64 = 0
    public var Ttbr1: uint64 = 0

    public init() {}

    public init(_ v: hypervisor.Vcpu) {
        Sctlr = (try? v.Get(hypervisor.RegArm64.sctlr_el1)) ?? 0
        Tcr = (try? v.Get(hypervisor.RegArm64.tcr_el1)) ?? 0
        Ttbr0 = (try? v.Get(hypervisor.RegArm64.ttbr0_el1)) ?? 0
        Ttbr1 = (try? v.Get(hypervisor.RegArm64.ttbr1_el1)) ?? 0
    }

    /// The guest-physical address `va` maps to, or nil. 4 KiB granule only,
    /// which is what Linux, Windows and EDK2 use.
    public func Translate(_ va: uint64, memory: device.GuestMemory) -> uint64? {
        if Sctlr & 1 == 0 { return va }   // MMU off: identity
        let upper = (va >> 63) != 0
        let tsz = upper ? (Tcr >> 16) & 0x3f : Tcr & 0x3f
        let tg = upper ? (Tcr >> 30) & 3 : (Tcr >> 14) & 3
        let is4k = upper ? tg == 2 : tg == 0
        if !is4k { return nil }
        let bits = 64 - tsz
        // TTBR1 addresses are sign-extended; the walk sees only the low bits.
        let va = va & ((uint64(1) << bits) - 1)
        var level = bits > 39 ? 0 : (bits > 30 ? 1 : 2)
        var table = (upper ? Ttbr1 : Ttbr0) & 0x0000_ffff_ffff_fffe
        while level <= 3 {
            let shift = uint64(39 - 9 * level)
            let index = (va >> shift) & 0x1ff
            guard let d = try? memory.Load64(device.GuestAddress(table + index * 8)) else { return nil }
            if d & 1 == 0 { return nil }
            let out = d & 0x0000_ffff_ffff_f000
            if level == 3 {
                return out | (va & 0xfff)
            }
            if d & 2 == 0 {
                // A block: 1 GiB at level 1, 2 MiB at level 2.
                let mask = (uint64(1) << shift) - 1
                return (out & ~mask) | (va & mask)
            }
            table = out
            level += 1
        }
        return nil
    }

    /// Reads `count` bytes at a guest-virtual address, page by page.
    public func Read(_ va: uint64, count: int, memory: device.GuestMemory) -> [uint8]? {
        var out: [uint8] = []
        var at = va
        while out.count < count {
            guard let pa = Translate(at, memory: memory) else { return nil }
            let inPage = int(0x1000 - (at & 0xfff))
            let n = min(inPage, count - out.count)
            guard let b = try? memory.Read(device.GuestAddress(pa), count: n) else { return nil }
            out.append(contentsOf: b)
            at += uint64(n)
        }
        return out
    }
}
