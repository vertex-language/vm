package vm

import (
    "io"
    "os/process"
    "sync"
    "vm/chipset"
    "vm/device"
    "vm/hypervisor"
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

    // 3. Storage devices
    var slot = 0
    for storage in cfg.Storage {
        let blk = virtio.Block(storage.Image)
        let irqLine = PlatformArm64.VirtioIrqBase + uint32(slot)
        let irq = GicIrq(partition: partition, line: irqLine)
        let transport = virtio.MmioTransport(blk, memory: ram.Memory, irq: irq)
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
        let transport = virtio.MmioTransport(vnet, memory: ram.Memory, irq: irq)
        let addr = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
        try wired.MmioBus.Insert(transport, at: device.Range(base: addr, count: PlatformArm64.VirtioMmioSize))
        wired.VirtioTransports.append(transport)
        slot += 1
    }

    // 5. Input devices (keyboard and tablet when display is enabled)
    if cfg.Display.Enabled {
        // 5a. Keyboard input device
        let kbd = virtio.Input(.keyboard)
        let irqLineKbd = PlatformArm64.VirtioIrqBase + uint32(slot)
        let irqKbd = GicIrq(partition: partition, line: irqLineKbd)
        let transportKbd = virtio.MmioTransport(kbd, memory: ram.Memory, irq: irqKbd)
        let addrKbd = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
        try wired.MmioBus.Insert(transportKbd, at: device.Range(base: addrKbd, count: PlatformArm64.VirtioMmioSize))
        wired.VirtioTransports.append(transportKbd)
        wired.KeyboardInput = kbd
        slot += 1

        // 5b. Tablet input device
        let tablet = virtio.Input(.tablet)
        let irqLineTablet = PlatformArm64.VirtioIrqBase + uint32(slot)
        let irqTablet = GicIrq(partition: partition, line: irqLineTablet)
        let transportTablet = virtio.MmioTransport(tablet, memory: ram.Memory, irq: irqTablet)
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
    let transportRng = virtio.MmioTransport(rng, memory: ram.Memory, irq: irqRng)
    let addrRng = PlatformArm64.VirtioMmioBase + uint64(slot) * PlatformArm64.VirtioMmioStride
    try wired.MmioBus.Insert(transportRng, at: device.Range(base: addrRng, count: PlatformArm64.VirtioMmioSize))
    wired.VirtioTransports.append(transportRng)
    wired.Rng = rng
    slot += 1

    wired.VirtioCount = slot
    return wired
}
