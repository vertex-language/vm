package hypervisor

public struct RegArm64 {
    public static let x0: int32 = 0
    public static let sp: int32 = 31
    public static let pc: int32 = 32
    public static let pstate: int32 = 33
    public static let mpidr: int32 = 34
    public static let elr_el1: int32 = 35
    public static let esr_el1: int32 = 36
    public static let far_el1: int32 = 37
    public static let vbar_el1: int32 = 38

    /// Any other system register, by its MRS encoding.
    public static func Sys(op0: int32, op1: int32, crn: int32, crm: int32, op2: int32) -> int32 {
        0x10000 | (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2
    }

    public static let sctlr_el1 = Sys(op0: 3, op1: 0, crn: 1, crm: 0, op2: 0)
    public static let ttbr0_el1 = Sys(op0: 3, op1: 0, crn: 2, crm: 0, op2: 0)
    public static let ttbr1_el1 = Sys(op0: 3, op1: 0, crn: 2, crm: 0, op2: 1)
    public static let tcr_el1 = Sys(op0: 3, op1: 0, crn: 2, crm: 0, op2: 2)
    public static let spsr_el1 = Sys(op0: 3, op1: 0, crn: 4, crm: 0, op2: 0)
    public static let sp_el0 = Sys(op0: 3, op1: 0, crn: 4, crm: 1, op2: 0)
    public static let cntv_ctl_el0 = Sys(op0: 3, op1: 3, crn: 14, crm: 3, op2: 1)
    public static let cntv_cval_el0 = Sys(op0: 3, op1: 3, crn: 14, crm: 3, op2: 2)
    public static let cntp_ctl_el0 = Sys(op0: 3, op1: 3, crn: 14, crm: 2, op2: 1)
    public static let cntp_cval_el0 = Sys(op0: 3, op1: 3, crn: 14, crm: 2, op2: 2)
}

/// An arm64 vCPU's general registers: what a boot protocol sets and a
/// PSCI call reads.
public struct Registers {
    /// x0 through x30.
    public var X: [uint64] = [uint64](repeating: 0, count: 31)
    /// SP_EL1.
    public var Sp: uint64 = 0
    public var Pc: uint64 = 0
    /// PSTATE / CPSR. 0x3c5 is EL1h with D, A, I and F masked: the state
    /// Linux wants at its entry point.
    public var Pstate: uint64 = 0x3c5
    public var ElrEl1: uint64 = 0
    public var EsrEl1: uint64 = 0
    public var FarEl1: uint64 = 0
    public var VbarEl1: uint64 = 0

    public init() {}
}

extension Vcpu {
    public func GetRegisters() throws -> Registers {
        var r = hypervisor.Registers()
        for i in 0..<31 {
            r.X[i] = try Get(RegArm64.x0 + int32(i))
        }
        r.Sp = try Get(RegArm64.sp)
        r.Pc = try Get(RegArm64.pc)
        r.Pstate = try Get(RegArm64.pstate)
        r.ElrEl1 = (try? self.Get(RegArm64.elr_el1)) ?? 0
        r.EsrEl1 = (try? self.Get(RegArm64.esr_el1)) ?? 0
        r.FarEl1 = (try? self.Get(RegArm64.far_el1)) ?? 0
        r.VbarEl1 = (try? self.Get(RegArm64.vbar_el1)) ?? 0
        return r
    }

    public func SetRegisters(_ r: Registers) throws {
        for i in 0..<31 {
            try Set(RegArm64.x0 + int32(i), r.X[i])
        }
        try Set(RegArm64.sp, r.Sp)
        try Set(RegArm64.pc, r.Pc)
        try Set(RegArm64.pstate, r.Pstate)
    }
}
