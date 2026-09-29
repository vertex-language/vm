package hypervisor

public struct RegAmd64 {
    public static let rax: int32 = 0
    public static let rcx: int32 = 1
    public static let rdx: int32 = 2
    public static let rbx: int32 = 3
    public static let rsp: int32 = 4
    public static let rbp: int32 = 5
    public static let rsi: int32 = 6
    public static let rdi: int32 = 7
    public static let r8: int32 = 8
    public static let rip: int32 = 16
    public static let rflags: int32 = 17
    public static let cr0: int32 = 18
    public static let cr3: int32 = 19
    public static let cr4: int32 = 20
    public static let efer: int32 = 21
}

public struct SegAmd64 {
    public static let cs: int32 = 0
    public static let ds: int32 = 1
    public static let es: int32 = 2
    public static let fs: int32 = 3
    public static let gs: int32 = 4
    public static let ss: int32 = 5
    public static let tr: int32 = 6
    public static let ldtr: int32 = 7
    public static let gdtr: int32 = 8
    public static let idtr: int32 = 9
}

/// An amd64 vCPU's general and control registers.
public struct Registers {
    /// rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8..r15, in encoding order.
    public var Gpr: [uint64] = [uint64](repeating: 0, count: 16)
    public var Rip: uint64 = 0
    /// Bit 1 is reserved and always set.
    public var Rflags: uint64 = 0x2
    public var Cr0: uint64 = 0
    public var Cr3: uint64 = 0
    public var Cr4: uint64 = 0
    public var Efer: uint64 = 0

    public init() {}
}

/// Which segment register `SetSegment` writes.
public enum Segment: int32 {
    case cs = 0, ds, es, fs, gs, ss, tr, ldtr
}

/// A segment descriptor as the vCPU holds it. `Attributes` is the VMX
/// access-rights layout: type (bits 0–3), S, DPL, P, AVL, L, D/B, G.
public struct SegmentDescriptor {
    public var Base: uint64
    public var Limit: uint32
    public var Selector: uint16
    public var Attributes: uint16

    public init(base: uint64 = 0, limit: uint32 = 0xffff_ffff, selector: uint16, attributes: uint16) {
        Base = base
        Limit = limit
        Selector = selector
        Attributes = attributes
    }

    /// 32-bit flat code, as PVH enters with: execute/read, accessed, 4 GiB.
    public static let flatCode32 = SegmentDescriptor(selector: 0x10, attributes: 0xc09b)
    /// 32-bit flat data: read/write, accessed, 4 GiB.
    public static let flatData32 = SegmentDescriptor(selector: 0x18, attributes: 0xc093)
    /// A busy 32-bit TSS, which VT-x insists on even when it's never used.
    public static let tss = SegmentDescriptor(limit: 0x67, selector: 0x20, attributes: 0x008b)
}

extension Vcpu {
    public func GetRegisters() throws -> Registers {
        var r = hypervisor.Registers()
        for i in 0..<16 {
            r.Gpr[i] = try Get(int32(i))
        }
        r.Rip = try Get(RegAmd64.rip)
        r.Rflags = try Get(RegAmd64.rflags)
        r.Cr0 = try Get(RegAmd64.cr0)
        r.Cr3 = try Get(RegAmd64.cr3)
        r.Cr4 = try Get(RegAmd64.cr4)
        r.Efer = try Get(RegAmd64.efer)
        return r
    }

    public func SetRegisters(_ r: Registers) throws {
        for i in 0..<16 {
            try Set(int32(i), r.Gpr[i])
        }
        try Set(RegAmd64.rip, r.Rip)
        try Set(RegAmd64.rflags, r.Rflags)
        try Set(RegAmd64.cr0, r.Cr0)
        try Set(RegAmd64.cr3, r.Cr3)
        try Set(RegAmd64.cr4, r.Cr4)
        try Set(RegAmd64.efer, r.Efer)
    }

    public func SetSegment(_ seg: Segment, _ d: SegmentDescriptor) throws {
        try check(hvSetSegment(handle, seg.rawValue, d.Base, d.Limit, d.Selector, d.Attributes),
                  "setting segment \(seg)")
    }

    /// Sets the GDTR or IDTR.
    public func SetDescriptorTable(gdt: bool, base: uint64, limit: uint16) throws {
        let which = gdt ? SegAmd64.gdtr : SegAmd64.idtr
        try check(hvSetSegment(handle, which, base, uint32(limit), 0, 0), "setting a descriptor table")
    }
}
