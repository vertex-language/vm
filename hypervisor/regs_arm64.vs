package hypervisor

public struct RegArm64 {
    public static let x0: int32 = 0
    public static let sp: int32 = 31
    public static let pc: int32 = 32
    public static let pstate: int32 = 33
    public static let mpidr: int32 = 34
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
