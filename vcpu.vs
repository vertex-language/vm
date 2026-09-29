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

    var vcpu: hypervisor.Vcpu? = nil
    var thread: sync.Thread? = nil
    var running = false
    var stopped = false
    let lock = sync.Mutex()

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

        while true {
            let isRunning = lock.withLock { running && !stopped }
            if !isRunning { break }

            do {
                let exit = try v.Run()
                switch exit {
                case .mmio(let mmio):
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
                    let cont = try psci.Handle(vcpu: v, call: h)
                    if !cont {
                        lock.withLock { stopped = true; running = false }
                    }

                case .systemRegister:
                    try v.Complete()

                case .timer:
                    try v.UnmaskTimer()

                case .halt:
                    try v.Complete()
                    time.Sleep(time.Duration.Microseconds(200))

                case .canceled:
                    let stillRunning = lock.withLock { running }
                    if !stillRunning {
                        lock.withLock { stopped = true }
                    }

                case .shutdown:
                    psci.controller.RequestShutdown()
                    lock.withLock { stopped = true; running = false }

                case .failed(let code):
                    psci.controller.RequestShutdown()
                    lock.withLock { stopped = true; running = false }

                case .cpuid:
                    try v.Complete()
                }
            } catch {
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
