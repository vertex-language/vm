package vm

import (
    "fs"
    "fs/mmap"
    "io"
    "sync"
    "time"
    "vm/acpi"
    "vm/boot"
    "vm/chipset"
    "vm/device"
    "vm/disk"
    "vm/disk/qcow2"
    "vm/disk/vhdx"
    "vm/display"
    "vm/hypervisor"
    "vm/usb"
    "vm/virtio"
)

/// The status returned when a virtual machine stops execution.
public enum ExitStatus: Equatable, CustomStringConvertible {
    case poweredOff
    case reset
    case crashed(string)

    public var description: string {
        switch self {
        case .poweredOff: return "powered off"
        case .reset: return "reset requested"
        case .crashed(let reason): return "crashed: \(reason)"
        }
    }
}

/// A running virtual machine.
public final class Machine: PsciController {
    public let Config: Config
    public let Partition: hypervisor.Partition
    public let Ram: GuestRam
    public let Wired: WiredDevices

    public var ConsoleUart: chipset.Pl011? { Wired.ConsoleUart }
    public var KeyboardInput: virtio.Input? { Wired.KeyboardInput }
    public var TabletInput: virtio.Input? { Wired.TabletInput }
    /// Android guests' touchscreen and keys.
    public var GoldfishEvents: chipset.GoldfishEvents? { Wired.GoldfishEvents }
    /// A Windows guest's USB keyboard and tablet.
    public var UsbKeyboard: usb.Keyboard? { Wired.UsbKeyboard }
    public var UsbTablet: usb.Tablet? { Wired.UsbTablet }
    public var Framebuffer: display.Framebuffer? = nil
    var fbMapping: mmap.Mapping? = nil
    var flash0: GuestRam? = nil
    public var Pflash: chipset.PflashCfi01? = nil

    var psci: PsciHandler? = nil
    var vcpus: [VcpuWorker] = []
    public var Vcpus: [VcpuWorker] { vcpus }
    var running = false
    var exitStatus: ExitStatus = .poweredOff
    var exitRequested = false
    let lock = sync.Mutex()
    var closed = false

    init(
        config: Config,
        partition: hypervisor.Partition,
        ram: GuestRam,
        wired: WiredDevices
    ) {
        self.Config = config
        self.Partition = partition
        self.Ram = ram
        self.Wired = wired
    }

    /// Creates and configures a new virtual machine from `cfg`.
    public static func Create(_ cfg: Config, consoleWriter: any io.AsyncWriter = StdioWriter()) throws -> Machine {
        if cfg.Cpus < 1 {
            throw VmError.invalidConfig("vCPU count must be at least 1")
        }
        if cfg.Memory < (64 << 20) {
            throw VmError.invalidConfig("memory must be at least 64 MiB")
        }

        let caps = try? hypervisor.Probe()
        if caps == nil {
            throw VmError.hypervisorUnavailable("hypervisor probe failed or not supported on this host")
        }

        // 1. Allocate guest physical RAM
        let ramBase = PlatformArm64.RamBase
        let ram = try GuestRam(base: ramBase, size: cfg.Memory)

        // 2. Create the hypervisor partition and map RAM
        let partition = try hypervisor.Create(vcpus: cfg.Cpus)
        try ram.Map(into: partition)

        // 3. Create the in-kernel GICv3 interrupt controller on arm64
        try partition.CreateIrqChip(
            distributor: PlatformArm64.GicDistBase,
            redistributor: PlatformArm64.GicRedistBase,
            msiBase: PlatformArm64.GicMsiBase,
            msiFirst: PlatformArm64.GicMsiSpiBase,
            msiCount: PlatformArm64.GicMsiSpiCount
        )

        // 4. Wire platform devices (UART, RTC, VirtIO)
        let wired = try WirePlatform(
            cfg: cfg,
            partition: partition,
            ram: ram,
            consoleWriter: consoleWriter
        )

        let machine = Machine(
            config: cfg,
            partition: partition,
            ram: ram,
            wired: wired
        )
        let psci = PsciHandler(controller: machine)
        machine.psci = psci

        // 4b. Framebuffer setup (if enabled)
        var fbConfig: FramebufferConfig? = nil
        if let gf = wired.GoldfishFb {
            machine.Framebuffer = gf.Framebuffer
        } else if cfg.Display.Enabled {
            let width = cfg.Display.Width
            let height = cfg.Display.Height
            let cfgFb = FramebufferConfig(
                base: PlatformArm64.FbBase,
                width: width,
                height: height,
                format: "a8r8g8b8"
            )
            fbConfig = cfgFb
            let mapping = try mmap.Anonymous(int(PlatformArm64.FbSize))
            guard let ptr = mapping.RawPointer else {
                throw VmError.memoryAllocationFailed("failed to allocate \(PlatformArm64.FbSize) bytes for framebuffer")
            }
            try partition.Map(guest: PlatformArm64.FbBase, host: ptr, count: PlatformArm64.FbSize, access: .all)
            let region = device.Region(guest: device.GuestAddress(PlatformArm64.FbBase), count: PlatformArm64.FbSize, host: ptr)
            let fbMem = device.GuestMemory([region])
            let fb = display.Framebuffer(memory: fbMem, hostPointer: ptr)
            fb.Configure(
                address: device.GuestAddress(PlatformArm64.FbBase),
                width: width,
                height: height,
                stride: width * 4,
                format: .xrgb8888
            )
            machine.Framebuffer = fb
            machine.fbMapping = mapping
        }

        // 5. Configure boot loader
        var bootPc: uint64 = 0
        var bootX0: uint64 = 0

        if let b = cfg.Boot {
            switch b {
            case .linux(let kernel, let initrd, let cmdline):
                let plan = try boot.LinuxArm64(
                    kernel: kernel,
                    initrd: initrd,
                    cmdline: cmdline,
                    ram: ram.Range
                )

                // Write kernel and initrd into guest memory
                for load in plan.Loads {
                    try ram.Memory.Write(load.Address, load.Bytes)
                }

                // Generate and write Device Tree (DTB)
                let dtb = PlatformArm64.BuildFdt(
                    vcpus: cfg.Cpus,
                    ram: ram.Range,
                    initrd: plan.Initrd,
                    cmdline: plan.Cmdline,
                    virtioCount: wired.VirtioCount,
                    framebuffer: fbConfig,
                    goldfishFb: wired.GoldfishFb != nil,
                    goldfishEvents: wired.GoldfishEvents != nil,
                    goldfishBattery: wired.GoldfishBattery != nil
                )
                if let dtbAddr = plan.DeviceTree {
                    try ram.Memory.Write(dtbAddr, dtb)
                }

                switch plan.Entry {
                case .arm64(let pc, let x0):
                    bootPc = pc
                    bootX0 = x0
                default:
                    throw VmError.bootFailed("unsupported entry mode for arm64")
                }

            case .efi(let firmware, let vars):
                // 1. Allocate and map Flash 0 (Code) at 0x0000_0000 (64 MiB)
                let flash0 = try GuestRam(base: PlatformArm64.Flash0Base, size: PlatformArm64.Flash0Size)
                try flash0.Map(into: partition)
                try flash0.Memory.Write(device.GuestAddress(PlatformArm64.Flash0Base), firmware)
                machine.flash0 = flash0

                // 2. Attach Flash 1 (Vars) as PflashCfi01 MMIO device at 0x0400_0000 (64 MiB)
                let pflash = chipset.PflashCfi01(size: int(PlatformArm64.Flash1Size), initialData: vars)
                try wired.MmioBus.Insert(pflash, at: device.Range(base: PlatformArm64.Flash1Base, count: PlatformArm64.Flash1Size))
                machine.Pflash = pflash

                // 3. Framebuffer hook: if Ramfb was wired, assign to machine.Framebuffer
                if let rfb = wired.Ramfb {
                    machine.Framebuffer = rfb.Framebuffer
                }

                // 4. Inject ACPI tables via fw_cfg for UEFI guests (Windows & Linux)
                if let fwcfg = wired.FwCfg {
                    var acpiCfg = acpi.Arm64Config(
                        vcpus: cfg.Cpus,
                        virtioCount: wired.VirtioCount,
                        pciMmio64Base: PlatformArm64.PciMmio64Base,
                        pciMmio64Size: PlatformArm64.PciMmio64Size
                    )
                    acpiCfg.MsiFrameBase = PlatformArm64.GicMsiBase
                    acpiCfg.MsiSpiBase = PlatformArm64.GicMsiSpiBase
                    acpiCfg.MsiSpiCount = PlatformArm64.GicMsiSpiCount
                    if wired.Tpm != nil {
                        acpiCfg.TpmBase = PlatformArm64.TpmBase
                    }
                    let payload = acpi.BuildArm64(acpiCfg)
                    fwcfg.Add(boot.FwCfg.File(name: "etc/acpi/tables", bytes: payload.Tables))
                    fwcfg.Add(boot.FwCfg.File(name: "etc/acpi/rsdp", bytes: payload.Rsdp))
                    fwcfg.Add(boot.FwCfg.File(name: "etc/table-loader", bytes: payload.Loader))
                }

                // 5. Generate Device Tree (DTB) for UEFI
                let dtb = PlatformArm64.BuildFdt(
                    vcpus: cfg.Cpus,
                    ram: ram.Range,
                    initrd: nil,
                    cmdline: "",
                    virtioCount: wired.VirtioCount,
                    framebuffer: fbConfig,
                    enableFwCfg: wired.FwCfg != nil,
                    enableFlash: true,
                    enablePci: wired.PciRoot != nil,
                    enableTpm: wired.Tpm != nil
                )

                // 5. Place DTB at start of RAM (0x4000_0000)
                let dtbAddr = PlatformArm64.RamBase
                try ram.Memory.Write(device.GuestAddress(dtbAddr), dtb)

                // 6. vCPU 0 resets at Flash 0 base (0x0000_0000) with X0 pointing to DTB
                bootPc = PlatformArm64.Flash0Base
                bootX0 = dtbAddr
            }
        }

        // 6. Create vCPUs
        for i in 0..<cfg.Cpus {
            let isBoot = (i == 0)
            let worker = VcpuWorker(
                id: i,
                partition: partition,
                mmioBus: wired.MmioBus,
                pioBus: wired.PioBus,
                psci: psci,
                isBootCpu: isBoot,
                entryPc: isBoot ? bootPc : 0,
                entryX0: isBoot ? bootX0 : 0
            )
            worker.GroupOneAtReset = cfg.Boot != nil && !isEfiBoot(cfg.Boot)
            machine.vcpus.append(worker)
        }

        return machine
    }

    /// Starts execution of the virtual machine.
    public func Start() throws {
        lock.withLock {
            if running { return }
            running = true
            exitRequested = false
        }
        // Start the boot vCPU (vCPU 0). Secondary CPUs are powered on via PSCI.
        vcpus[0].Start()
    }

    /// Stops all vCPUs cleanly.
    public func Terminate() {
        lock.withLock {
            exitRequested = true
            exitStatus = .poweredOff
        }
        for v in vcpus {
            v.Stop()
        }
    }

    /// Kills the virtual machine immediately.
    public func Kill() {
        Terminate()
    }

    /// Awaits until the virtual machine shuts down, resets, or crashes.
    public func Wait() async throws -> ExitStatus {
        while true {
            let done = lock.withLock { exitRequested }
            if done { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms poll
        }
        // Join all vCPU threads
        for v in vcpus {
            v.Join()
        }
        return lock.withLock { exitStatus }
    }

    public func Close() {
        if closed { return }
        closed = true
        Terminate()
        for v in vcpus {
            v.Join()
        }
        Partition.Close()
        Wired.Tpm?.Shutdown()
        flash0 = nil
        Pflash = nil
        fbMapping = nil
    }

    deinit {
        Close()
    }

    // MARK: - PsciController Protocol

    public func StartVcpu(mpidr: uint64, entry: uint64, context: uint64) -> int64 {
        let id = int(mpidr & 0xff)
        if id < 0 || id >= vcpus.count {
            return psciInvalidParams
        }
        let v = vcpus[id]
        if v.running {
            return psciAlreadyOn
        }
        v.EntryPc = entry
        v.EntryX0 = context
        v.EntryPstate = 0x3c5
        v.Start()
        return psciSuccess
    }

    public func StopVcpu(_ id: int) {
        if id >= 0 && id < vcpus.count {
            vcpus[id].Stop()
        }
    }

    public func VcpuAffinity(mpidr: uint64) -> int64 {
        let id = int(mpidr & 0xff)
        if id < 0 || id >= vcpus.count {
            return 1 // OFF
        }
        return vcpus[id].running ? 0 : 1 // 0 = ON, 1 = OFF
    }

    public func RequestShutdown() {
        lock.withLock {
            exitRequested = true
            exitStatus = .poweredOff
        }
        for v in vcpus {
            v.Stop()
        }
    }

    public func RequestReset() {
        lock.withLock {
            exitRequested = true
            exitStatus = .reset
        }
        for v in vcpus {
            v.Stop()
        }
    }
}

/// Convenience function to create and open a disk image from a file path.
public func OpenDisk(_ path: fs.Path, readOnly: bool = false) async throws -> any disk.Image {
    let pathStr = path.Value
    let isIsoPath = pathStr.hasSuffix(".iso") || pathStr.hasSuffix(".ISO")
    let forceRo = readOnly || isIsoPath

    var opt = fs.OpenOptions()
    opt.Read = true
    opt.Write = !forceRo
    let f = try fs.Open(path, opt)
    defer { try? f.Close() }
    var magic = [uint8](repeating: 0, count: 8)
    _ = try? f.Read(into: &magic)

    // QCOW2 magic: "QFI\xfb"
    if magic.count >= 4 && magic[0] == 0x51 && magic[1] == 0x46 && magic[2] == 0x49 && magic[3] == 0xfb {
        let file = try fs.Open(path, opt)
        return try qcow2.Open(file)
    }

    // VHDX magic: "vhdxfile"
    let magicStr = string(decoding: magic, as: UTF8.self)
    if magicStr.starts(with: "vhdx") {
        let file = try fs.Open(path, opt)
        return try vhdx.Open(file)
    }

    // Check for ISO 9660 volume descriptor at offset 32768
    var pvdMagic = [uint8](repeating: 0, count: 6)
    if let n = try? f.Read(into: &pvdMagic, at: int64(disk.IsoPvdOffset)), n >= 6 {
        if pvdMagic[0] == 1 && pvdMagic[1] == 0x43 && pvdMagic[2] == 0x44 && pvdMagic[3] == 0x30 && pvdMagic[4] == 0x30 && pvdMagic[5] == 0x31 {
            return try disk.OpenRaw(path, readOnly: true)
        }
    }

    return try disk.OpenRaw(path, readOnly: forceRo)
}

/// Entry point to create a VM: `vm.Create(cfg)`.
public func Create(_ cfg: Config, consoleWriter: any io.AsyncWriter = StdioWriter()) throws -> Machine {
    try Machine.Create(cfg, consoleWriter: consoleWriter)
}
