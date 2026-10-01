package vm

import (
    "crypto/rand"
    "encoding/binary"
    "vm/hypervisor"
)

let psciVersion: uint32          = 0x8400_0000
let psciCpuSuspend32: uint32    = 0x8400_0001
let psciCpuSuspend64: uint32    = 0xc400_0001
let psciCpuOff: uint32           = 0x8400_0002
let psciCpuOn32: uint32         = 0x8400_0003
let psciCpuOn64: uint32         = 0xc400_0003
let psciAffinityInfo32: uint32  = 0x8400_0004
let psciAffinityInfo64: uint32  = 0xc400_0004
let psciMigrateInfoType: uint32 = 0x8400_0006
let psciSystemOff: uint32        = 0x8400_0008
let psciSystemReset: uint32      = 0x8400_0009
let psciFeatures: uint32         = 0x8400_000a

let smcccTrngVersion: uint32     = 0x8400_0050
let smcccTrngFeatures: uint32    = 0x8400_0051
let smcccTrngRnd32: uint32       = 0x8400_0053
let smcccTrngRnd64: uint32       = 0xc400_0053

let psciSuccess: int64         = 0
let psciNotSupported: int64    = -1
let psciInvalidParams: int64   = -2
let psciDenied: int64          = -3
let psciAlreadyOn: int64       = -4

public protocol PsciController: AnyObject {
    func StartVcpu(mpidr: uint64, entry: uint64, context: uint64) -> int64
    func StopVcpu(_ id: int)
    func VcpuAffinity(mpidr: uint64) -> int64
    func RequestShutdown()
    func RequestReset()
}

public final class PsciHandler {
    let controller: any PsciController

    public init(controller: any PsciController) {
        self.controller = controller
    }

    /// Handles an HVC hypercall exit on arm64. Returns false if the vCPU should stop.
    public func Handle(vcpu: hypervisor.Vcpu, call: hypervisor.Hypercall) throws -> bool {
        let fid = uint32(truncatingIfNeeded: call.Args.0)
        var result: int64 = psciNotSupported
        var continueVcpu = true

        switch fid {
        case psciVersion:
            result = 0x0001_0000 // PSCI v1.0

        case psciFeatures:
            let feat = uint32(truncatingIfNeeded: call.Args.1)
            switch feat {
            case psciCpuSuspend32, psciCpuSuspend64:
                result = 0   // original power_state format, no OS-initiated mode
            case psciVersion, psciFeatures, psciCpuOn64, psciCpuOn32,
                 psciCpuOff, psciAffinityInfo64, psciAffinityInfo32,
                 psciSystemOff, psciSystemReset:
                result = 0
            default:
                result = psciNotSupported
            }

        case psciCpuSuspend32, psciCpuSuspend64:
            // Every state is treated as standby, as QEMU does: return at
            // once, which the caller sees as a wakeup.
            result = psciSuccess

        case psciCpuOn64, psciCpuOn32:
            let targetMpidr = call.Args.1
            let entry = call.Args.2
            let context = call.Args.3
            result = controller.StartVcpu(mpidr: targetMpidr, entry: entry, context: context)

        case psciCpuOff:
            controller.StopVcpu(vcpu.Id)
            continueVcpu = false

        case psciAffinityInfo64, psciAffinityInfo32:
            let targetMpidr = call.Args.1
            result = controller.VcpuAffinity(mpidr: targetMpidr)

        case psciMigrateInfoType:
            result = 2 // not supported

        case psciSystemOff:
            controller.RequestShutdown()
            continueVcpu = false

        case psciSystemReset:
            controller.RequestReset()
            continueVcpu = false

        case smcccTrngVersion:
            result = 0x0001_0000 // SMCCC TRNG v1.0

        case smcccTrngFeatures:
            result = 0 // supported

        case smcccTrngRnd64, smcccTrngRnd32:
            result = 0 // success
            if let b = try? rand.Bytes(24) {
                let r1 = binary.LittleEndian.Uint64(b, from: 0)
                let r2 = binary.LittleEndian.Uint64(b, from: 8)
                let r3 = binary.LittleEndian.Uint64(b, from: 16)
                try vcpu.Set(hypervisor.RegArm64.x0 + 1, r1)
                try vcpu.Set(hypervisor.RegArm64.x0 + 2, r2)
                try vcpu.Set(hypervisor.RegArm64.x0 + 3, r3)
            }

        default:
            result = psciNotSupported
        }

        try vcpu.Set(hypervisor.RegArm64.x0, uint64(bitPattern: result))
        try vcpu.Complete()
        return continueVcpu
    }
}
