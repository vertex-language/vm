package acpi

import (
    "encoding/binary"
)

public struct Arm64Config {
    public var Vcpus: int
    public var VirtioCount: int
    public var GicDistBase: uint64
    public var GicRedistBase: uint64
    public var GicRedistSizePerCpu: uint64
    public var PciEcamBase: uint64
    public var PciMmio32Base: uint64
    public var PciMmio32Size: uint64
    public var PciMmio64Base: uint64
    public var PciMmio64Size: uint64
    public var VirtioMmioBase: uint64
    public var VirtioMmioStride: uint64
    public var VirtioMmioSize: uint64
    public var VirtioIrqBase: uint32
    /// The SPI PCI INTA of slot 0 lands on; INTx swizzle over four from it.
    public var PciIntxSpi: uint32 = 3
    /// A GIC MSI frame for PCI MSIs, and the SPIs it raises; 0 for none.
    public var MsiFrameBase: uint64 = 0
    public var MsiSpiBase: uint32 = 0
    public var MsiSpiCount: uint32 = 0
    public var UartBase: uint64
    public var UartSize: uint64
    public var UartIrq: uint32
    public var RtcBase: uint64
    public var RtcSize: uint64
    public var RtcIrq: uint32

    public init(
        vcpus: int = 2,
        virtioCount: int = 0,
        gicDistBase: uint64 = 0x0800_0000,
        gicRedistBase: uint64 = 0x080a_0000,
        gicRedistSizePerCpu: uint64 = 0x0002_0000,
        pciEcamBase: uint64 = 0x1000_0000,
        pciMmio32Base: uint64 = 0x2000_0000,
        pciMmio32Size: uint64 = 0x1000_0000,
        pciMmio64Base: uint64 = 0x04_0000_0000,
        pciMmio64Size: uint64 = 0x04_0000_0000,
        virtioMmioBase: uint64 = 0x0a00_0000,
        virtioMmioStride: uint64 = 0x0000_1000,
        virtioMmioSize: uint64 = 0x0000_0200,
        virtioIrqBase: uint32 = 16,
        uartBase: uint64 = 0x0900_0000,
        uartSize: uint64 = 0x0000_1000,
        uartIrq: uint32 = 1,
        rtcBase: uint64 = 0x0901_0000,
        rtcSize: uint64 = 0x0000_1000,
        rtcIrq: uint32 = 2
    ) {
        self.Vcpus = vcpus
        self.VirtioCount = virtioCount
        self.GicDistBase = gicDistBase
        self.GicRedistBase = gicRedistBase
        self.GicRedistSizePerCpu = gicRedistSizePerCpu
        self.PciEcamBase = pciEcamBase
        self.PciMmio32Base = pciMmio32Base
        self.PciMmio32Size = pciMmio32Size
        self.PciMmio64Base = pciMmio64Base
        self.PciMmio64Size = pciMmio64Size
        self.VirtioMmioBase = virtioMmioBase
        self.VirtioMmioStride = virtioMmioStride
        self.VirtioMmioSize = virtioMmioSize
        self.VirtioIrqBase = virtioIrqBase
        self.UartBase = uartBase
        self.UartSize = uartSize
        self.UartIrq = uartIrq
        self.RtcBase = rtcBase
        self.RtcSize = rtcSize
        self.RtcIrq = rtcIrq
    }
}

public struct Payload {
    public let Tables: [uint8]
    public let Rsdp: [uint8]
    public let Loader: [uint8]

    public init(tables: [uint8], rsdp: [uint8], loader: [uint8]) {
        self.Tables = tables
        self.Rsdp = rsdp
        self.Loader = loader
    }
}

/// Builds the complete set of ACPI tables and QEMU linker/loader commands for ARM64 UEFI.
public func BuildArm64(_ cfg: Arm64Config) -> Payload {
    // 1. DSDT with ARM64 devices: CPUs, GED, PowerButton, PCIe Root, VirtIO MMIO, UART, RTC
    var sb = Aml()

    // 1a. CPUs (ACPI0007)
    for i in 0..<cfg.Vcpus {
        var cpu = Aml()
        cpu.Name("_HID", Aml.String("ACPI0007"))
        cpu.Name("_UID", Aml.Integer(uint64(i)))
        let name = i < 10 ? "C00\(i)" : "C0\(i)"
        sb.Device(name, cpu)
    }

    // 1b. Generic Event Device (GED0: ACPI0013) & Power Button (PWRB: PNP0C0C)
    var ged = Aml()
    ged.Name("_HID", Aml.String("ACPI0013"))
    ged.Name("_UID", Aml.Integer(0))
    var gedRes = Resources()
    gedRes.Interrupt(43, edge: true) // SPI 11 = GSI 43
    ged.Name("_CRS", gedRes.Template())
    ged.NotifyMethod("_EVT", target: "PWRB", value: 0x80)
    sb.Device("GED0", ged)

    var pwrb = Aml()
    pwrb.Name("_HID", Aml.String("PNP0C0C"))
    pwrb.Name("_UID", Aml.Integer(0))
    sb.Device("PWRB", pwrb)

    // 1c. PCI Express Root Complex (PCI0: PNP0A08 / PNP0A03)
    var pci = Aml()
    pci.Name("_HID", Aml.String("PNP0A08"))
    pci.Name("_CID", Aml.String("PNP0A03"))
    pci.Name("_SEG", Aml.Integer(0))
    pci.Name("_BBN", Aml.Integer(0))
    pci.Name("_UID", Aml.Integer(0))
    pci.Name("_CCA", Aml.Integer(1)) // Cache coherent DMA

    var pciRes = Resources()
    pciRes.WordBusNumber(minBus: 0, maxBus: 15)
    pciRes.DWordMemory(base: uint32(cfg.PciMmio32Base), size: uint32(cfg.PciMmio32Size))
    pciRes.QWordMemory(base: cfg.PciMmio64Base, size: cfg.PciMmio64Size)
    pciRes.DWordIo(min: 0, max: 0xffff, translation: 0x3eff_0000, length: 0x0001_0000)
    pci.Name("_CRS", pciRes.Template())

    // _PRT: PCI interrupt routing table for slots 0..31
    var prtPkgs: [Aml] = []
    for dev in 0..<32 {
        for pin in 0..<4 {
            let addr = (uint64(dev) << 16) | 0xffff
            let gsi = uint64(32 + cfg.PciIntxSpi) + uint64((dev + pin) % 4)
            prtPkgs.append(Aml.Package([
                Aml.Integer(addr),
                Aml.Integer(uint64(pin)),
                Aml.Integer(0),
                Aml.Integer(gsi)
            ]))
        }
    }
    pci.Name("_PRT", Aml.Package(prtPkgs))
    sb.Device("PCI0", pci)

    // 1d. VirtIO MMIO devices (LNRO0005)
    for i in 0..<cfg.VirtioCount {
        var vdev = Aml()
        vdev.Name("_HID", Aml.String("LNRO0005"))
        vdev.Name("_UID", Aml.Integer(uint64(i)))
        vdev.Name("_CCA", Aml.Integer(1))
        var vres = Resources()
        let addr = cfg.VirtioMmioBase + uint64(i) * cfg.VirtioMmioStride
        vres.Memory32(base: uint32(addr), count: uint32(cfg.VirtioMmioSize))
        vres.Interrupt(cfg.VirtioIrqBase + uint32(i) + 32)
        vdev.Name("_CRS", vres.Template())
        let devName = i < 10 ? "VR0\(i)" : "VR\(i)"
        sb.Device(devName, vdev)
    }

    // 1e. PL011 UART (ARMH0011)
    var uart = Aml()
    uart.Name("_HID", Aml.String("ARMH0011"))
    uart.Name("_UID", Aml.Integer(0))
    var uartRes = Resources()
    uartRes.Memory32(base: uint32(cfg.UartBase), count: uint32(cfg.UartSize))
    uartRes.Interrupt(cfg.UartIrq + 32)
    uart.Name("_CRS", uartRes.Template())
    sb.Device("COM0", uart)

    // 1f. PL031 RTC (ARMH0031)
    var rtc = Aml()
    rtc.Name("_HID", Aml.String("ARMH0031"))
    rtc.Name("_UID", Aml.Integer(0))
    var rtcRes = Resources()
    rtcRes.Memory32(base: uint32(cfg.RtcBase), count: uint32(cfg.RtcSize))
    rtcRes.Interrupt(cfg.RtcIrq + 32)
    rtc.Name("_CRS", rtcRes.Template())
    sb.Device("RTC0", rtc)

    var topAml = Aml()
    topAml.Scope("\\_SB_", sb)
    let dsdtBytes = Dsdt(topAml)

    // 2. FADT (ARM64 HW-reduced, PSCI HVC)
    let fadtBytes = Fadt(FadtOptions(dsdt: 0, arm: true))

    // 3. MADT (GICv3)
    var madtArm = Madt.Arm64(
        cpus: cfg.Vcpus,
        distributor: cfg.GicDistBase,
        redistributor: cfg.GicRedistBase,
        redistributorSize: uint32(cfg.GicRedistSizePerCpu * uint64(cfg.Vcpus))
    )
    madtArm.MsiFrame = cfg.MsiFrameBase
    madtArm.MsiSpiBase = cfg.MsiSpiBase
    madtArm.MsiSpiCount = cfg.MsiSpiCount
    let madtBytes = Madt.Build(madtArm)

    // 4. GTDT (ARM Generic Timer)
    let gtdtBytes = Gtdt(virtualTimerIrq: 27)

    // 5. MCFG (PCIe ECAM)
    let mcfgBytes = Mcfg(ecam: cfg.PciEcamBase, segment: 0, startBus: 0, endBus: 15)

    // 6. SPCR (PL011 console redirection)
    let spcrBytes = Spcr(kind: .pl011, address: cfg.UartBase, irq: cfg.UartIrq + 32, io: false)

    // 7. Assemble "etc/acpi/tables"
    var tables: [uint8] = []

    func align16(_ b: inout [uint8]) {
        let rem = b.count % 16
        if rem != 0 {
            b.append(contentsOf: [uint8](repeating: 0, count: 16 - rem))
        }
    }

    let dsdtOffset = tables.count
    tables.append(contentsOf: dsdtBytes)
    align16(&tables)

    let fadtOffset = tables.count
    tables.append(contentsOf: fadtBytes)
    align16(&tables)

    let madtOffset = tables.count
    tables.append(contentsOf: madtBytes)
    align16(&tables)

    let gtdtOffset = tables.count
    tables.append(contentsOf: gtdtBytes)
    align16(&tables)

    let mcfgOffset = tables.count
    tables.append(contentsOf: mcfgBytes)
    align16(&tables)

    let spcrOffset = tables.count
    tables.append(contentsOf: spcrBytes)
    align16(&tables)

    // XSDT with 5 table entries: FADT, MADT, GTDT, MCFG, SPCR
    let xsdtDummy = [uint64](repeating: 0, count: 5)
    let xsdtBytes = Xsdt(xsdtDummy)
    let xsdtOffset = tables.count
    tables.append(contentsOf: xsdtBytes)
    align16(&tables)

    // 8. Build "etc/table-loader" commands
    var loader = TableLoader()

    // 8a. Allocate tables and rsdp
    loader.Allocate(file: "etc/acpi/tables", align: 64, zone: 1)
    loader.Allocate(file: "etc/acpi/rsdp", align: 16, zone: 1)

    // 8b. Link FADT -> DSDT at offset 140 (X_DSDT)
    binary.LittleEndian.PutUint64(&tables, uint64(dsdtOffset), at: fadtOffset + 140)
    loader.AddPointer(destFile: "etc/acpi/tables", destOffset: uint32(fadtOffset + 140), size: 8, srcFile: "etc/acpi/tables")
    loader.AddChecksum(file: "etc/acpi/tables", resultOffset: uint32(fadtOffset + 9), start: uint32(fadtOffset), length: uint32(fadtBytes.count))

    // 8c. Link XSDT entries -> FADT, MADT, GTDT, MCFG, SPCR
    let targetOffsets: [int] = [fadtOffset, madtOffset, gtdtOffset, mcfgOffset, spcrOffset]
    for i in 0..<targetOffsets.count {
        let entryOffset = xsdtOffset + 36 + i * 8
        binary.LittleEndian.PutUint64(&tables, uint64(targetOffsets[i]), at: entryOffset)
        loader.AddPointer(destFile: "etc/acpi/tables", destOffset: uint32(entryOffset), size: 8, srcFile: "etc/acpi/tables")
    }
    loader.AddChecksum(file: "etc/acpi/tables", resultOffset: uint32(xsdtOffset + 9), start: uint32(xsdtOffset), length: uint32(xsdtBytes.count))

    // The firmware computes each checksum over the field itself, so a
    // checksum the loader recomputes must start out 0. EDK2 skips any
    // table whose bytes don't sum to 0, and Windows can't find the FADT.
    tables[fadtOffset + 9] = 0
    tables[xsdtOffset + 9] = 0

    // 9. Build "etc/acpi/rsdp" and link RSDP -> XSDT
    var rsdpBytes = Rsdp(xsdt: uint64(xsdtOffset))
    rsdpBytes[8] = 0
    rsdpBytes[32] = 0
    loader.AddPointer(destFile: "etc/acpi/rsdp", destOffset: 24, size: 8, srcFile: "etc/acpi/tables")
    loader.AddChecksum(file: "etc/acpi/rsdp", resultOffset: 8, start: 0, length: 20)
    loader.AddChecksum(file: "etc/acpi/rsdp", resultOffset: 32, start: 0, length: 36)

    return Payload(tables: tables, rsdp: rsdpBytes, loader: loader.Bytes)
}
