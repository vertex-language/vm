package vm

import (
    "io"
    "os/process"
    "sync"
    "vm/boot"
    "vm/chipset"
    "vm/device"
    "vm/display"
    "vm/goldfish"
    "vm/hypervisor"
    "vm/nvme"
    "vm/pci"
    "vm/tpm"
    "vm/usb"
    "vm/virtio"
    "net/ether"
)

/// GicIrq routes an interrupt line to an in-kernel GIC SPI.
public final class GicIrq: device.Irq {
    let partition: hypervisor.Partition
    public let Line: uint32

    public init(partition: hypervisor.Partition, line: uint32) {
        self.partition = partition
        self.Line = line
    }

    public func Set(_ level: bool) {
        try? partition.SetIrq(Line, level: level)
    }

    public func Pulse() {
        Set(true)
        Set(false)
    }
}

/// GicMsi delivers a PCI function's MSI write to the in-kernel GIC's MSI
/// frame, which raises the SPI the data names.
public final class GicMsi: device.Msi {
    let partition: hypervisor.Partition

    public init(partition: hypervisor.Partition) {
        self.partition = partition
    }

    public func Send(address: uint64, data: uint32) {
        try? partition.SendMsi(address: address, data: data)
    }
}

/// StdioWriter forwards guest console writes to the host process's stdout.
public final class StdioWriter: io.AsyncWriter {
    public init() {}

    public func Write(_ bytes: borrowing [uint8]) async throws {
        var out = process.Stdout
        try await out.Write(bytes)
    }

    public func Flush() async throws {
        var out = process.Stdout
        try await out.Flush()
    }
}

/// MemoryConsole captures guest console output in a thread-safe buffer for testing or inspection.
public final class MemoryConsole: io.AsyncWriter {
    public private(set) var Bytes: [uint8] = []
    let lock = sync.Mutex()

    public init() {}

    public func Write(_ bytes: borrowing [uint8]) async throws {
        lock.withLock {
            Bytes.append(contentsOf: bytes)
        }
    }

    public func Flush() async throws {}

    public var Text: string {
        lock.withLock {
            string(decoding: Bytes, as: UTF8.self)
        }
    }
}

public struct WiredDevices {
    public var MmioBus = device.MmioBus()
    public var PioBus = device.PioBus()
    public var ConsoleUart: chipset.Pl011? = nil
    public var VirtioTransports: [virtio.MmioTransport] = []
    public var KeyboardInput: virtio.Input? = nil
    public var TabletInput: virtio.Input? = nil
    public var Rng: virtio.Rng? = nil
    public var VirtioCount: int = 0
    public var FwCfg: boot.FwCfg? = nil
    public var PciRoot: pci.Root? = nil
    public var Ramfb: display.Ramfb? = nil
    /// Android guests: the emulator's screen and its touchscreen and keys.
    public var GoldfishFb: goldfish.Fb? = nil
    public var GoldfishEvents: goldfish.Events? = nil
    public var GoldfishBattery: goldfish.Battery? = nil
    public var GoldfishPipe: goldfish.Pipe? = nil
    /// Windows guests: the inbox-driver devices on PCI.
    public var Xhci: usb.Xhci? = nil
    public var UsbKeyboard: usb.Keyboard? = nil
    public var UsbTablet: usb.Tablet? = nil
    public var Nvme: nvme.Controller? = nil
    public var Tpm: tpm.Tis? = nil
}

func isEfiBoot(_ b: Boot?) -> bool {
    if let boot = b {
        switch boot {
        case .efi: return true
        default: return false
        }
    }
    return false
}

/// WirePlatform instantiates and places devices on the buses according to the config.
public func WirePlatform(
    cfg: Config,
    partition: hypervisor.Partition,
    ram: GuestRam,
    consoleWriter: any io.AsyncWriter = StdioWriter()
) throws -> WiredDevices {
    var wired = WiredDevices()

    // 1. Console UART
    let uartIrq = GicIrq(partition: partition, line: PlatformArm64.UartIrq)
    let uart = chipset.Pl011(output: consoleWriter, irq: uartIrq)
    try wired.MmioBus.Insert(uart, at: device.Range(base: PlatformArm64.UartBase, count: PlatformArm64.UartSize))
    wired.ConsoleUart = uart

    // 2. Real-Time Clock
    let rtcIrq = GicIrq(partition: partition, line: PlatformArm64.RtcIrq)
    let rtc = chipset.Pl031(irq: rtcIrq)
    try wired.MmioBus.Insert(rtc, at: device.Range(base: PlatformArm64.RtcBase, count: PlatformArm64.RtcSize))

    // 3. fw_cfg device (for UEFI / Standard / Windows)
    if cfg.Profile == .standard || cfg.Guest == .windows || isEfiBoot(cfg.Boot) {
        let fwcfg = boot.FwCfg(memory: ram.Memory)
        try wired.MmioBus.Insert(fwcfg, at: device.Range(base: PlatformArm64.FwCfgBase, count: PlatformArm64.FwCfgSize))
        wired.FwCfg = fwcfg

        if cfg.Display.Enabled || cfg.Guest == .windows || isEfiBoot(cfg.Boot) {
            let rfb = display.Ramfb(memory: ram.Memory, fwcfg: fwcfg)
            wired.Ramfb = rfb
        }
    }

    // A TPM 2.0, for UEFI guests.
    if let role = cfg.Tpm, isEfiBoot(cfg.Boot) {
        switch role {
        case .swtpm(let stateDir):
            let tis = tpm.Tis(backend: tpm.Swtpm(stateDir: stateDir))
            try wired.MmioBus.Insert(tis, at: device.Range(base: PlatformArm64.TpmBase, count: tpm.Tis.Size))
            wired.Tpm = tis
        }
    }

    // 4. PCIe Root Complex (for Standard / Windows)
    if cfg.Profile == .standard || cfg.Guest == .windows || isEfiBoot(cfg.Boot) {
        let pciLayout = pci.Layout(
            ecam: device.Range(base: PlatformArm64.PciEcamBase, count: PlatformArm64.PciEcamSize),
            mmio32: device.Range(base: PlatformArm64.PciMmio32Base, count: PlatformArm64.PciMmio32Size),
            mmio64: device.Range(base: PlatformArm64.PciMmio64Base, count: PlatformArm64.PciMmio64Size),
            irqBase: PlatformArm64.PciIntxSpi
        )
        let pciRoot = pci.Root(pciLayout, intx: { line in GicIrq(partition: partition, line: line) })
        try wired.MmioBus.Insert(pciRoot, at: pciLayout.Ecam)
        // BARs are wherever the firmware or OS programs them; the
        // apertures decode them.
        try wired.MmioBus.Insert(pciRoot.MmioWindow(pciLayout.Mmio32), at: pciLayout.Mmio32)
        try wired.MmioBus.Insert(pciRoot.MmioWindow(pciLayout.Mmio64), at: pciLayout.Mmio64)
        wired.PciRoot = pciRoot
    }

    // Windows drives none of the VirtIO devices with an inbox driver, so
    // it gets what it does drive: xHCI with a keyboard, a tablet and the
    // installer as a USB CD-ROM, and NVMe for disks.
    if cfg.Guest == .windows, let root = wired.PciRoot {
        let msi = GicMsi(partition: partition)
        let xhci = usb.Xhci(memory: ram.Memory, msi: msi)
        let kbd = usb.Keyboard()
        let tablet = usb.Tablet()
        xhci.Plug(kbd)
        xhci.Plug(tablet)
        var disks: [StorageRole] = []
        for storage in cfg.Storage {
            if storage.IsInstaller {
                xhci.Plug(usb.Storage(storage.Image, kind: .cdrom))
            } else {
                disks.append(storage)
            }
        }
        _ = try root.Attach(xhci)
        wired.Xhci = xhci
        wired.UsbKeyboard = kbd
        wired.UsbTablet = tablet
        if !disks.isEmpty {
            let ctrl = nvme.Controller(memory: ram.Memory, msi: msi)
            for d in disks { ctrl.Attach(d.Image) }
            _ = try root.Attach(ctrl)
            wired.Nvme = ctrl
        }
        return wired
    }

    // 3. Storage devices
    var slot = 0
    for storage in cfg.Storage {
        let blk = virtio.Block(storage.Image)
        let irqLine = PlatformArm64.VirtioIrqBase + uint32(slot)
        let irq = GicIrq(partition: partition, line: irqLine)
        let transport = virtio.MmioTransport(blk, memory: ram.Memory, irq: irq, legacy: cfg.LegacyVirtio)
        let addr = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
        try wired.MmioBus.Insert(transport, at: device.Range(base: addr, count: PlatformArm64.VirtioMmioSize))
        wired.VirtioTransports.append(transport)
        slot += 1
    }

    // 4. Network devices
    for netRole in cfg.Network {
        let vnet = virtio.Net(port: netRole.Port)
        let irqLine = PlatformArm64.VirtioIrqBase + uint32(slot)
        let irq = GicIrq(partition: partition, line: irqLine)
        let transport = virtio.MmioTransport(vnet, memory: ram.Memory, irq: irq, legacy: cfg.LegacyVirtio)
        let addr = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
        try wired.MmioBus.Insert(transport, at: device.Range(base: addr, count: PlatformArm64.VirtioMmioSize))
        wired.VirtioTransports.append(transport)
        slot += 1
    }

    // Android's battery, always full on mains power.
    if cfg.Guest == .android {
        let battery = goldfish.Battery()
        try wired.MmioBus.Insert(battery, at: device.Range(base: PlatformArm64.GoldfishBatteryBase, count: PlatformArm64.GoldfishSize))
        wired.GoldfishBattery = battery
        // The pipe to host services (qemud, the GPU), which the guest's
        // services find by name.
        let pipeIrq = GicIrq(partition: partition, line: PlatformArm64.GoldfishPipeIrq)
        let pipe = goldfish.Pipe(memory: ram.Memory, irq: pipeIrq)
        try wired.MmioBus.Insert(pipe, at: device.Range(base: PlatformArm64.GoldfishPipeBase, count: goldfish.Pipe.Size))
        wired.GoldfishPipe = pipe
    }

    // Android's screen: goldfish-fb, pixels in guest RAM.
    if cfg.Guest == .android && cfg.Display.Enabled {
        let irq = GicIrq(partition: partition, line: PlatformArm64.GoldfishFbIrq)
        let fb = goldfish.Fb(memory: ram.Memory, irq: irq, width: cfg.Display.Width, height: cfg.Display.Height)
        try wired.MmioBus.Insert(fb, at: device.Range(base: PlatformArm64.GoldfishFbBase, count: PlatformArm64.GoldfishSize))
        wired.GoldfishFb = fb
        let evIrq = GicIrq(partition: partition, line: PlatformArm64.GoldfishEventsIrq)
        let events = goldfish.Events(irq: evIrq, width: cfg.Display.Width, height: cfg.Display.Height)
        try wired.MmioBus.Insert(events, at: device.Range(base: PlatformArm64.GoldfishEventsBase, count: PlatformArm64.GoldfishSize))
        wired.GoldfishEvents = events
    }

    // 5. Input devices (keyboard and tablet when display is enabled)
    if cfg.Display.Enabled && cfg.Guest != .android {
        // 5a. Keyboard input device
        let kbd = virtio.Input(.keyboard)
        let irqLineKbd = PlatformArm64.VirtioIrqBase + uint32(slot)
        let irqKbd = GicIrq(partition: partition, line: irqLineKbd)
        let transportKbd = virtio.MmioTransport(kbd, memory: ram.Memory, irq: irqKbd, legacy: cfg.LegacyVirtio)
        let addrKbd = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
        try wired.MmioBus.Insert(transportKbd, at: device.Range(base: addrKbd, count: PlatformArm64.VirtioMmioSize))
        wired.VirtioTransports.append(transportKbd)
        wired.KeyboardInput = kbd
        slot += 1

        // 5b. Tablet input device
        let tablet = virtio.Input(.tablet)
        let irqLineTablet = PlatformArm64.VirtioIrqBase + uint32(slot)
        let irqTablet = GicIrq(partition: partition, line: irqLineTablet)
        let transportTablet = virtio.MmioTransport(tablet, memory: ram.Memory, irq: irqTablet, legacy: cfg.LegacyVirtio)
        let addrTablet = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
        try wired.MmioBus.Insert(transportTablet, at: device.Range(base: addrTablet, count: PlatformArm64.VirtioMmioSize))
        wired.VirtioTransports.append(transportTablet)
        wired.TabletInput = tablet
        slot += 1
    }

    // 6. Entropy / RNG device
    let rng = virtio.Rng()
    let irqLineRng = PlatformArm64.VirtioIrqBase + uint32(slot)
    let irqRng = GicIrq(partition: partition, line: irqLineRng)
    let transportRng = virtio.MmioTransport(rng, memory: ram.Memory, irq: irqRng, legacy: cfg.LegacyVirtio)
    let addrRng = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
    try wired.MmioBus.Insert(transportRng, at: device.Range(base: addrRng, count: PlatformArm64.VirtioMmioSize))
    wired.VirtioTransports.append(transportRng)
    wired.Rng = rng
    slot += 1

    wired.VirtioCount = slot
    return wired
}
