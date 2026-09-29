package vm

import (
    "vm/hypervisor"
)

let psciVersion: uint32          = 0x8400_0000
let psciCpuOff: uint32           = 0x8400_0002
let psciCpuOn32: uint32         = 0x8400_0003
let psciCpuOn64: uint32         = 0xc400_0003
let psciAffinityInfo32: uint32  = 0x8400_0004
let psciAffinityInfo64: uint32  = 0xc400_0004
let psciMigrateInfoType: uint32 = 0x8400_0006
let psciSystemOff: uint32        = 0x8400_0008
let psciSystemReset: uint32      = 0x8400_0009
let psciFeatures: uint32         = 0x8400_000a

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
            case psciVersion, psciFeatures, psciCpuOn64, psciCpuOn32,
                 psciCpuOff, psciAffinityInfo64, psciAffinityInfo32,
                 psciSystemOff, psciSystemReset:
                result = 0
            default:
                result = psciNotSupported
            }

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

        default:
            result = psciNotSupported
        }

        try vcpu.Set(hypervisor.RegArm64.x0, uint64(bitPattern: result))
        try vcpu.Complete()
        return continueVcpu
    }
}
