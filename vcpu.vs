package vm

import (
    "sync"
    "time"
    "vm/device"
    "vm/hypervisor"
)

/// VcpuWorker manages a vCPU instance running on its own dedicated OS thread.
public final class VcpuWorker {
    public let Id: int
    let partition: hypervisor.Partition
    let mmioBus: device.MmioBus
    let pioBus: device.PioBus
    let psci: PsciHandler
    let isBootCpu: bool

    public var EntryPc: uint64
    public var EntryX0: uint64
    public var EntryPstate: uint64 = 0x3c5
    /// Puts every interrupt in Group 1 (non-secure) before the guest runs,
    /// as firmware would: for a kernel booted directly. Linux before 4.x
    /// leaves the groups as it finds them, and the GIC resets them to
    /// Group 0, which it signals as FIQs the kernel never takes. QEMU does
    /// the same for direct boots.
    public var GroupOneAtReset = false

    var vcpu: hypervisor.Vcpu? = nil
    var thread: sync.Thread? = nil
    var running = false
    var stopped = false
    let lock = sync.Mutex()

    var dumpRequested = false
    var lastDump: string = ""
    /// Exit counts by kind, for diagnostics: mmio, hypercall, sysreg, halt, timer, canceled, other.
    public var ExitCounts: [int] = [int](repeating: 0, count: 7)

    public init(
        id: int,
        partition: hypervisor.Partition,
        mmioBus: device.MmioBus,
        pioBus: device.PioBus,
        psci: PsciHandler,
        isBootCpu: bool = false,
        entryPc: uint64 = 0,
        entryX0: uint64 = 0
    ) {
        self.Id = id
        self.partition = partition
        self.mmioBus = mmioBus
        self.pioBus = pioBus
        self.psci = psci
        self.isBootCpu = isBootCpu
        self.EntryPc = entryPc
        self.EntryX0 = entryX0
    }

    /// Spawns the dedicated thread and enters the execution loop.
    public func Start() {
        lock.withLock {
            if running { return }
            running = true
            stopped = false
        }
        thread = sync.Thread.spawn { [self] in
            self.run()
        }
    }

    /// Signals the vCPU to stop and kicks it out of the guest.
    public func Stop() {
        lock.withLock {
            running = false
        }
        vcpu?.Kick()
    }

    public func Join() {
        thread?.join()
    }

    /// Describes the vCPU's registers. HVF only lets the owning thread read
    /// them, so this kicks the vCPU and waits for its thread to answer.
    public func CurrentState() -> (uint64, uint64, string) {
        let alive = lock.withLock { running && !stopped }
        if !alive {
            return (0, 0, lock.withLock { lastDump.isEmpty ? "not running" : lastDump })
        }
        lock.withLock { dumpRequested = true }
        vcpu?.Kick()
        for _ in 0..<200 {
            let done = lock.withLock { !dumpRequested }
            if done { break }
            time.Sleep(time.Duration.Milliseconds(5))
        }
        let s = lock.withLock { lastDump }
        return (lastPc, lastSp, s)
    }

    var lastPc: uint64 = 0
    var lastSp: uint64 = 0
    /// The registers as of the last `CurrentState` or fault dump.
    public var LastRegisters: hypervisor.Registers? = nil
    /// The translation registers as of the last dump.
    public var LastMmu: Arm64Mmu? = nil

    func describe(_ v: hypervisor.Vcpu) -> string {
        guard let regs = try? v.GetRegisters() else { return "unreadable" }
        LastRegisters = regs
        lastPc = regs.Pc
        lastSp = regs.Sp
        var s = "PC=0x\(string(regs.Pc, radix: 16)) SP=0x\(string(regs.Sp, radix: 16)) PSTATE=0x\(string(regs.Pstate, radix: 16))\n"
        for j in 0..<31 {
            s += "  X\(j)=0x\(string(regs.X[j], radix: 16))"
            if j % 4 == 3 { s += "\n" }
        }
        s += "\n  ELR=0x\(string(regs.ElrEl1, radix: 16)) ESR=0x\(string(regs.EsrEl1, radix: 16)) FAR=0x\(string(regs.FarEl1, radix: 16)) VBAR=0x\(string(regs.VbarEl1, radix: 16))"
        let mmu = Arm64Mmu(v)
        LastMmu = mmu
        let g = { (r: int32) -> string in string((try? v.Get(r)) ?? 0, radix: 16) }
        s += "\n  SCTLR=0x\(string(mmu.Sctlr, radix: 16)) TCR=0x\(string(mmu.Tcr, radix: 16)) TTBR0=0x\(string(mmu.Ttbr0, radix: 16)) TTBR1=0x\(string(mmu.Ttbr1, radix: 16))"
        s += "\n  SPSR=0x\(g(hypervisor.RegArm64.spsr_el1)) SP_EL0=0x\(g(hypervisor.RegArm64.sp_el0)) CNTV_CTL=0x\(g(hypervisor.RegArm64.cntv_ctl_el0)) CNTV_CVAL=0x\(g(hypervisor.RegArm64.cntv_cval_el0)) CNTP_CTL=0x\(g(hypervisor.RegArm64.cntp_ctl_el0)) CNTP_CVAL=0x\(g(hypervisor.RegArm64.cntp_cval_el0))"
        // Interrupt state (HVF's register numbers): SPIs 32-63 pending and
        // active, this CPU's SGIs and PPIs, and its priority state.
        let gic = { (k: int32, r: uint32) -> string in
            if let v = try? v.GicReg(kind: k, r) { return "0x" + string(v, radix: 16) }
            return "?"
        }
        s += "\n  GICD ISPENDR1=\(gic(0, 0x204)) ISACTIVER1=\(gic(0, 0x304)) ISENABLER1=\(gic(0, 0x104))"
        s += "\n  GICD CTLR=\(gic(0, 0x0)) IGROUPR1=\(gic(0, 0x84)) GICR IGROUPR0=\(gic(1, 0x10080)) IPRIORITYR27=\(gic(1, 0x10418)) ICC IGRPEN1=\(gic(2, 0xc667)) IGRPEN0=\(gic(2, 0xc666))"
        s += "\n  GICR ISPENDR0=\(gic(1, 0x10200)) ISACTIVER0=\(gic(1, 0x10300)) ISENABLER0=\(gic(1, 0x10100)) ICC PMR=\(gic(2, 0xc230)) RPR=\(gic(2, 0xc65b)) AP1R0=\(gic(2, 0xc648))"
        s += "\n  exits mmio=\(ExitCounts[0]) hvc=\(ExitCounts[1]) sysreg=\(ExitCounts[2]) wfi=\(ExitCounts[3]) vtimer=\(ExitCounts[4]) kick=\(ExitCounts[5]) other=\(ExitCounts[6])"
        return s
    }

    func run() {
        // HVF binds a vCPU to the thread that creates it:
        guard let v = try? partition.CreateVcpu(Id) else {
            lock.withLock { stopped = true; running = false }
            return
        }
        self.vcpu = v
        defer {
            v.Close()
            self.vcpu = nil
        }

        // Set initial registers
        var regs = hypervisor.Registers()
        regs.Pc = EntryPc
        regs.X[0] = EntryX0
        regs.Pstate = EntryPstate
        do {
            try v.SetRegisters(regs)
        } catch {
            lock.withLock { stopped = true; running = false }
            return
        }
        if GroupOneAtReset {
            // GICR_IGROUPR0: this CPU's SGIs and PPIs.
            try? v.SetGicReg(kind: 1, 0x1_0080, 0xffff_ffff)
            if isBootCpu {
                // GICD_IGROUPR1..31: the SPIs (writes past the last are ignored).
                for i in 1..<32 { try? v.SetGicReg(kind: 0, uint32(0x80 + 4 * i), 0xffff_ffff) }
            }
        }

        while true {
            let isRunning = lock.withLock { running && !stopped }
            if !isRunning { break }

            do {
                let exit = try v.Run()
                switch exit {
                case .mmio(let mmio):
                    ExitCounts[0] += 1
                    if let m = mmioBus.Find(mmio.Address) {
                        if mmio.Write {
                            m.dev.Write(offset: m.offset, size: mmio.Size, value: mmio.Value)
                            try v.Complete()
                        } else {
                            let val = m.dev.Read(offset: m.offset, size: mmio.Size)
                            try v.Complete(read: val)
                        }
                    } else {
                        // Unmapped read yields all 1s; write ignored
                        print("[unmapped MMIO] addr=0x\(string(mmio.Address, radix: 16)) write=\(mmio.Write) size=\(mmio.Size) val=0x\(string(mmio.Value, radix: 16))")
                        if mmio.Write {
                            try v.Complete()
                        } else {
                            try v.Complete(read: ~0)
                        }
                    }

                case .io(let io):
                    if let m = pioBus.Find(uint64(io.Port)) {
                        if io.Write {
                            m.dev.Write(port: io.Port, size: io.Size, value: io.Value)
                            try v.Complete()
                        } else {
                            let val = m.dev.Read(port: io.Port, size: io.Size)
                            try v.Complete(read: uint64(val))
                        }
                    } else {
                        try v.Complete(read: ~0)
                    }

                case .hypercall(let h):
                    ExitCounts[1] += 1
                    let cont = try psci.Handle(vcpu: v, call: h)
                    if !cont {
                        lock.withLock { stopped = true; running = false }
                    }

                case .systemRegister(let r):
                    ExitCounts[2] += 1
                    try v.Complete(read: trappedSysreg(r))

                case .timer:
                    ExitCounts[4] += 1
                    try v.UnmaskTimer()

                case .halt:
                    ExitCounts[3] += 1
                    try v.Complete()
                    time.Sleep(time.Duration.Microseconds(200))

                case .canceled:
                    ExitCounts[5] += 1
                    let wantDump = lock.withLock { dumpRequested }
                    if wantDump {
                        let d = describe(v)
                        lock.withLock { lastDump = d; dumpRequested = false }
                    }
                    let stillRunning = lock.withLock { running }
                    if !stillRunning {
                        lock.withLock { stopped = true }
                    }

                case .shutdown:
                    psci.controller.RequestShutdown()
                    lock.withLock { stopped = true; running = false }

                case .failed(let code):
                    ExitCounts[6] += 1
                    let d = describe(v)
                    print("[vCPU \(Id)] unhandled exit 0x\(string(code, radix: 16))\n\(d)")
                    lock.withLock { lastDump = d }
                    psci.controller.RequestShutdown()
                    lock.withLock { stopped = true; running = false }

                case .cpuid:
                    try v.Complete()
                }
            } catch {
                print("[vCPU \(Id)] stopped on error: \(error)\n\(describe(v))")
                lock.withLock { stopped = true; running = false }
                break
            }
        }

        lock.withLock {
            stopped = true
            running = false
        }
    }
}

/// The value of a system register the hypervisor trapped to us instead of
/// handling: the OS-lock and debug registers. Writes are ignored; reads not
/// listed are 0 (RAZ/WI), and logged once each, since an unknown one is
/// the first thing to suspect when a guest stops.
var loggedSysregs: Set<uint32> = []
let loggedSysregsLock = sync.Mutex()

func trappedSysreg(_ r: hypervisor.SystemRegisterAccess) -> uint64 {
    // ESR ISS: Op0[21:20] Op2[19:17] Op1[16:14] CRn[13:10] CRm[4:1].
    let op0 = (r.Id >> 20) & 3
    let op2 = (r.Id >> 17) & 7
    let op1 = (r.Id >> 14) & 7
    let crn = (r.Id >> 10) & 0xf
    let crm = (r.Id >> 1) & 0xf
    if op0 == 2 && op1 == 0 && crn == 1 && crm == 1 && op2 == 4 {
        return 0x8   // OSLSR_EL1: OS lock implemented (OSLM = 0b10), unlocked
    }
    if op0 == 2 && op1 == 0 && crn == 1 && (crm == 0 || crm == 3) && op2 == 4 {
        return 0     // OSLAR_EL1 / OSDLR_EL1
    }
    let first = loggedSysregsLock.withLock { loggedSysregs.insert(r.Id).inserted }
    if first {
        print("[vcpu] unhandled sysreg op0=\(op0) op1=\(op1) CRn=\(crn) CRm=\(crm) op2=\(op2) write=\(r.Write) value=0x\(string(r.Value, radix: 16))")
    }
    return 0
}
