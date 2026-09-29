package hypervisor

public let ExitWords: int = 8

/// Why `Vcpu.Run` returned. Every case carries plain values: nothing on
/// this path allocates, because it runs once per guest device access.
public enum Exit {
    /// The guest touched unmapped guest-physical memory: a device register.
    /// Answer a read with `Vcpu.Complete(read:)`.
    case mmio(MmioAccess)
    /// An x86 `in` / `out`. amd64 only.
    case io(PortAccess)
    /// HVC or SMC on arm64 (PSCI lives here), VMCALL on amd64 (Hyper-V).
    case hypercall(Hypercall)
    /// A trapped arm64 system register or amd64 MSR.
    case systemRegister(SystemRegisterAccess)
    /// CPUID (WHP only; KVM answers from the table vm gives it).
    case cpuid(leaf: uint32, subleaf: uint32)
    /// WFI / HLT with nothing pending: sleep until an interrupt or a kick.
    case halt
    /// The virtual timer fired (HVF). Deliver its PPI, then `UnmaskTimer`.
    case timer
    /// The guest can't go on: a triple fault, or a power-off the kernel
    /// handled (KVM PSCI).
    case shutdown
    /// `Kick` was called.
    case canceled
    /// Something the platform reported that this package doesn't model.
    case failed(code: uint64)
}

public struct MmioAccess {
    public let Address: uint64
    /// 1, 2, 4 or 8 bytes.
    public let Size: uint8
    public let Write: bool
    /// What was written; 0 for a read.
    public let Value: uint64
}

public struct PortAccess {
    public let Port: uint16
    public let Size: uint8
    public let Write: bool
    public let Value: uint32
}

public enum HypercallKind { case hvc, smc, vmcall }

public struct Hypercall {
    public let Kind: HypercallKind
    /// The instruction's immediate (arm64); 0 on amd64.
    public let Immediate: uint16
    /// x0..x3 on arm64; rcx, rdx, r8, r9 on amd64.
    public let Args: (uint64, uint64, uint64, uint64)
}

public struct SystemRegisterAccess {
    /// arm64: op0/op1/CRn/CRm/op2 as ESR packs them. amd64: the MSR number.
    public let Id: uint32
    public let Write: bool
    public let Value: uint64
}

package func decodeExit(_ kind: int32, _ w: borrowing [uint64]) -> Exit {
    switch kind {
    case ExitKind.mmio:
        return .mmio(MmioAccess(Address: w[0], Size: uint8(w[1]), Write: w[2] != 0, Value: w[3]))
    case ExitKind.io:
        return .io(PortAccess(Port: uint16(w[0]), Size: uint8(w[1]), Write: w[2] != 0, Value: uint32(w[3])))
    case ExitKind.hypercall:
        let k: HypercallKind = w[0] == uint64(CallKind.hvc) ? .hvc : (w[0] == uint64(CallKind.smc) ? .smc : .vmcall)
        return .hypercall(Hypercall(Kind: k, Immediate: uint16(w[1]), Args: (w[4], w[5], w[6], w[7])))
    case ExitKind.sysreg:
        return .systemRegister(SystemRegisterAccess(Id: uint32(w[0]), Write: w[2] != 0, Value: w[3]))
    case ExitKind.cpuid:
        return .cpuid(leaf: uint32(w[0]), subleaf: uint32(w[1]))
    case ExitKind.halt:
        return .halt
    case ExitKind.vtimer:
        return .timer
    case ExitKind.shutdown:
        return .shutdown
    case ExitKind.canceled:
        return .canceled
    default:
        return .failed(code: w[0])
    }
}
