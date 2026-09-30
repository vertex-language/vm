package vm

import (
    "crypto/rand"
    "encoding/binary"
    "encoding/fdt"
    "vm/device"
)

public struct PlatformArm64 {
    public static let RamBase: uint64          = 0x4000_0000
    public static let GicDistBase: uint64      = 0x0800_0000
    public static let GicDistSize: uint64      = 0x0001_0000
    public static let GicRedistBase: uint64    = 0x080a_0000
    public static let GicRedistSizePerCpu: uint64 = 0x0002_0000

    public static let UartBase: uint64         = 0x0900_0000
    public static let UartSize: uint64         = 0x0000_1000
    public static let UartIrq: uint32          = 1 // SPI 1 (line 33)

    public static let RtcBase: uint64          = 0x0901_0000
    public static let RtcSize: uint64          = 0x0000_1000
    public static let RtcIrq: uint32           = 2 // SPI 2 (line 34)

    public static let VirtioMmioBase: uint64   = 0x0a00_0000
    public static let VirtioMmioSize: uint64   = 0x0000_0200
    public static let VirtioMmioStride: uint64 = 0x0000_1000
    public static let VirtioIrqBase: uint32    = 16 // SPI 16.. (lines 48..)

    public static let PciEcamBase: uint64      = 0x1000_0000
    public static let PciEcamSize: uint64      = 0x1000_0000
    public static let PciMmio32Base: uint64    = 0x2000_0000
    public static let PciMmio32Size: uint64    = 0x2000_0000
    public static let PciMmio64Base: uint64    = 0x1_0000_0000
    public static let PciMmio64Size: uint64    = 0x1_0000_0000

    public static let FbBase: uint64           = 0x3000_0000
    public static let FbSize: uint64           = 0x0080_0000 // 8 MiB
}

public struct FramebufferConfig {
    public let Base: uint64
    public let Size: uint64
    public let Width: int
    public let Height: int
    public let Stride: int
    public let Format: string

    public init(
        base: uint64 = PlatformArm64.FbBase,
        width: int = 800,
        height: int = 600,
        format: string = "a8r8g8b8"
    ) {
        self.Base = base
        self.Width = width
        self.Height = height
        self.Stride = width * 4
        self.Size = uint64(height * width * 4)
        self.Format = format
    }
}

extension PlatformArm64 {
    /// Builds a Flattened Device Tree (DTB) describing this arm64 microVM for Linux.
    public static func BuildFdt(
        vcpus: int,
        ram: device.Range,
        initrd: device.Range? = nil,
        cmdline: string,
        virtioCount: int,
        framebuffer: FramebufferConfig? = nil
    ) -> [uint8] {
        let tree = fdt.Tree()

        // Root node
        tree.Root.AddProperty("#address-cells", uint32(2))
        tree.Root.AddProperty("#size-cells", uint32(2))
        tree.Root.AddProperty("compatible", strings: ["linux,dummy-virt", "vertex,microvm"])
        tree.Root.AddProperty("model", "vertex,microvm")
        tree.Root.AddProperty("interrupt-parent", uint32(1))

        // Chosen node
        let chosen = tree.Root.AddChild("chosen")
        let fullCmdline = cmdline.isEmpty ? "console=ttyAMA0 root=/dev/vda rw" : cmdline
        chosen.AddProperty("bootargs", fullCmdline)
        chosen.AddProperty("stdout-path", "/pl011@9000000")
        if let rd = initrd {
            chosen.AddProperty("linux,initrd-start", rd.Base)
            chosen.AddProperty("linux,initrd-end", rd.End)
        }

        // Entropy seeds: randomizes kernel address space (KASLR) and seeds CRNG early
        if let seedBytes = try? rand.Bytes(8) {
            let seed = binary.LittleEndian.Uint64(seedBytes, from: 0)
            chosen.AddProperty("kaslr-seed", seed)
        }
        if let rngSeed = try? rand.Bytes(32) {
            chosen.AddProperty("rng-seed", rngSeed)
        }

        // CPUs node
        let cpus = tree.Root.AddChild("cpus")
        cpus.AddProperty("#address-cells", uint32(1))
        cpus.AddProperty("#size-cells", uint32(0))
        for i in 0..<vcpus {
            let cpu = cpus.AddChild("cpu@\(i)")
            cpu.AddProperty("device_type", "cpu")
            cpu.AddProperty("compatible", "arm,arm-v8")
            cpu.AddProperty("reg", uint32(i))
            cpu.AddProperty("enable-method", "psci")
        }

        // PSCI node
        let psci = tree.Root.AddChild("psci")
        psci.AddProperty("compatible", strings: ["arm,psci-1.0", "arm,psci-0.2", "arm,psci"])
        psci.AddProperty("method", "hvc")

        // Memory node
        let mem = tree.Root.AddChild("memory@\(string(ram.Base, radix: 16))")
        mem.AddProperty("device_type", "memory")
        mem.AddProperty("reg", u64s: [ram.Base, ram.Count])

        // Interrupt Controller: GICv3
        let intc = tree.Root.AddChild("intc@\(string(GicDistBase, radix: 16))")
        intc.AddProperty("compatible", "arm,gic-v3")
        intc.AddProperty("#interrupt-cells", uint32(3))
        intc.AddEmptyProperty("interrupt-controller")
        let redistTotalSize = GicRedistSizePerCpu * uint64(vcpus)
        intc.AddProperty("reg", u64s: [GicDistBase, GicDistSize, GicRedistBase, redistTotalSize])
        intc.AddProperty("phandle", uint32(1))

        // Timer node
        let timer = tree.Root.AddChild("timer")
        timer.AddProperty("compatible", "arm,armv8-timer")
        timer.AddProperty("interrupt-parent", uint32(1))
        // 4 timers: secure physical, non-secure physical, virtual, hypervisor physical
        // Each has 3 cells: type (1 = PPI), interrupt number, flags (0xf08 = active-low level, all CPUs)
        timer.AddProperty("interrupts", u32s: [
            1, 13, 0xf08,
            1, 14, 0xf08,
            1, 11, 0xf08,
            1, 10, 0xf08
        ])

        // Fixed APB clock for peripherals
        let clk = tree.Root.AddChild("apb-pclk")
        clk.AddProperty("compatible", "fixed-clock")
        clk.AddProperty("#clock-cells", uint32(0))
        clk.AddProperty("clock-frequency", uint32(24_000_000))
        clk.AddProperty("clock-output-names", "clk24mhz")
        clk.AddProperty("phandle", uint32(2))

        // PL011 UART
        let uart = tree.Root.AddChild("pl011@\(string(UartBase, radix: 16))")
        uart.AddProperty("compatible", strings: ["arm,pl011", "arm,primecell"])
        uart.AddProperty("reg", u64s: [UartBase, UartSize])
        uart.AddProperty("interrupt-parent", uint32(1))
        // 0 = SPI, 1 = SPI line #1, 4 = level-sensitive high
        uart.AddProperty("interrupts", u32s: [0, UartIrq, 4])
        uart.AddProperty("clocks", u32s: [2, 2])
        uart.AddProperty("clock-names", strings: ["uartclk", "apb_pclk"])

        // PL031 RTC
        let rtc = tree.Root.AddChild("pl031@\(string(RtcBase, radix: 16))")
        rtc.AddProperty("compatible", strings: ["arm,pl031", "arm,primecell"])
        rtc.AddProperty("reg", u64s: [RtcBase, RtcSize])
        rtc.AddProperty("interrupt-parent", uint32(1))
        rtc.AddProperty("interrupts", u32s: [0, RtcIrq, 4])
        rtc.AddProperty("clocks", u32s: [2])
        rtc.AddProperty("clock-names", "apb_pclk")

        // VirtIO MMIO devices
        for i in 0..<virtioCount {
            let addr = VirtioMmioBase + uint64(i) * VirtioMmioStride
            let irqLine = VirtioIrqBase + uint32(i)
            let vdev = tree.Root.AddChild("virtio_mmio@\(string(addr, radix: 16))")
            vdev.AddProperty("compatible", "virtio,mmio")
            vdev.AddProperty("reg", u64s: [addr, VirtioMmioSize])
            vdev.AddProperty("interrupt-parent", uint32(1))
            vdev.AddProperty("interrupts", u32s: [0, irqLine, 4])
        }

        // simple-framebuffer device
        if let fb = framebuffer {
            let fbNode = tree.Root.AddChild("framebuffer@\(string(fb.Base, radix: 16))")
            fbNode.AddProperty("compatible", "simple-framebuffer")
            fbNode.AddProperty("reg", u64s: [fb.Base, fb.Size])
            fbNode.AddProperty("width", uint32(fb.Width))
            fbNode.AddProperty("height", uint32(fb.Height))
            fbNode.AddProperty("stride", uint32(fb.Stride))
            fbNode.AddProperty("format", fb.Format)
        }

        return tree.Encode()
    }
}
