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
    /// A GICv2m-style MSI frame (Hypervisor.framework's MSI region): a
    /// device's MSI write raises one of the SPIs it owns.
    public static let GicMsiBase: uint64       = 0x0802_0000
    public static let GicMsiSpiBase: uint32    = 128
    public static let GicMsiSpiCount: uint32   = 64

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
    public static let PciMmio32Size: uint64    = 0x1000_0000 // 256 MiB
    public static let PciMmio64Base: uint64    = 0x04_0000_0000 // 16 GiB
    public static let PciMmio64Size: uint64    = 0x04_0000_0000 // 16 GiB
    /// PCI INTA–INTD swizzle across SPIs 3...6, as on QEMU's virt.
    public static let PciIntxSpi: uint32       = 3

    public static let FbBase: uint64           = 0x3000_0000
    public static let FbSize: uint64           = 0x0080_0000 // 8 MiB

    /// A TPM's TIS registers, 5 localities of 4 KiB.
    public static let TpmBase: uint64          = 0x0c00_0000

    /// The Android emulator's devices (Guest.android).
    public static let GoldfishFbBase: uint64     = 0x0904_0000
    public static let GoldfishFbIrq: uint32      = 8 // SPI 8
    public static let GoldfishEventsBase: uint64 = 0x0905_0000
    public static let GoldfishEventsIrq: uint32  = 9 // SPI 9
    public static let GoldfishBatteryBase: uint64 = 0x0906_0000
    public static let GoldfishBatteryIrq: uint32  = 10 // SPI 10
    public static let GoldfishSize: uint64       = 0x0000_1000

    public static let FwCfgBase: uint64        = 0x0902_0000
    public static let FwCfgSize: uint64        = 0x0000_1000

    public static let Flash0Base: uint64       = 0x0000_0000
    public static let Flash0Size: uint64       = 64 << 20 // 64 MiB

    public static let Flash1Base: uint64       = 0x0400_0000
    public static let Flash1Size: uint64       = 64 << 20 // 64 MiB
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
        framebuffer: FramebufferConfig? = nil,
        enableFwCfg: bool = false,
        enableFlash: bool = false,
        enablePci: bool = false,
        enableTpm: bool = false,
        goldfishFb: bool = false,
        goldfishEvents: bool = false,
        goldfishBattery: bool = false
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

        // fw-cfg node
        if enableFwCfg {
            let fwcfg = tree.Root.AddChild("fw-cfg@\(string(FwCfgBase, radix: 16))")
            fwcfg.AddProperty("compatible", "qemu,fw-cfg-mmio")
            fwcfg.AddProperty("reg", u64s: [FwCfgBase, 0x18])
            fwcfg.AddEmptyProperty("dma-coherent")
        }

        // TPM 2.0, TIS over MMIO: what EDK2's Tpm2DeviceLib looks for.
        if enableTpm {
            let tpm = tree.Root.AddChild("tpm@\(string(TpmBase, radix: 16))")
            tpm.AddProperty("compatible", "tcg,tpm-tis-mmio")
            tpm.AddProperty("reg", u64s: [TpmBase, 0x5000])
        }

        // CFI Flash node
        if enableFlash {
            let flash = tree.Root.AddChild("flash@0")
            flash.AddProperty("compatible", "cfi-flash")
            flash.AddProperty("reg", u64s: [Flash0Base, Flash0Size, Flash1Base, Flash1Size])
            flash.AddProperty("bank-width", uint32(4))
        }

        // PCI Express Root Complex node
        if enablePci {
            let pcie = tree.Root.AddChild("pcie@\(string(PciEcamBase, radix: 16))")
            pcie.AddProperty("compatible", "pci-host-ecam-generic")
            pcie.AddProperty("device_type", "pci")
            pcie.AddProperty("#address-cells", uint32(3))
            pcie.AddProperty("#size-cells", uint32(2))
            pcie.AddProperty("#interrupt-cells", uint32(1))
            pcie.AddProperty("reg", u64s: [PciEcamBase, PciEcamSize])
            pcie.AddProperty("bus-range", u32s: [0, 15])
            pcie.AddEmptyProperty("dma-coherent")
            pcie.AddProperty("ranges", u32s: [
                0x0100_0000, 0, 0x0000_0000, 0, 0x3eff_0000, 0, 0x0001_0000,
                0x0200_0000, 0, 0x2000_0000, 0, 0x2000_0000, 0, 0x1000_0000,
                0x0300_0000, 4, 0, 4, 0, 4, 0
            ])
            pcie.AddProperty("interrupt-map-mask", u32s: [0x1800, 0, 0, 7])
            var intMap: [uint32] = []
            for dev in 0..<4 {
                for pin in 1...4 {
                    let devAddr = uint32(dev) << 11
                    let spiLine = PciIntxSpi + uint32((dev + pin - 1) % 4)
                    intMap.append(contentsOf: [
                        devAddr, 0, 0, uint32(pin),
                        1,
                        0, spiLine, 4
                    ])
                }
            }
            pcie.AddProperty("interrupt-map", u32s: intMap)
        }

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

        // The Android emulator's screen and input.
        if goldfishFb {
            let n = tree.Root.AddChild("goldfish_fb@\(string(GoldfishFbBase, radix: 16))")
            n.AddProperty("compatible", "generic,goldfish-fb")
            n.AddProperty("reg", u64s: [GoldfishFbBase, GoldfishSize])
            n.AddProperty("interrupts", u32s: [0, GoldfishFbIrq, 4])
        }
        if goldfishEvents {
            let n = tree.Root.AddChild("goldfish_events@\(string(GoldfishEventsBase, radix: 16))")
            n.AddProperty("compatible", "generic,goldfish-events-keypad")
            n.AddProperty("reg", u64s: [GoldfishEventsBase, GoldfishSize])
            n.AddProperty("interrupts", u32s: [0, GoldfishEventsIrq, 4])
        }

        if goldfishBattery {
            let n = tree.Root.AddChild("goldfish_battery@\(string(GoldfishBatteryBase, radix: 16))")
            n.AddProperty("compatible", "generic,goldfish-battery")
            n.AddProperty("reg", u64s: [GoldfishBatteryBase, GoldfishSize])
            n.AddProperty("interrupts", u32s: [0, GoldfishBatteryIrq, 4])
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
