package acpi

/// The Multiple APIC Description Table: the CPUs and their interrupt
/// controller. amd64: local APICs and an IOAPIC. arm64: GICC per CPU, the
/// GICD, the GICR range and (for MSIs) an ITS.
public enum Madt {
    public struct Amd64 {
        public var Cpus: int
        public var IoApic: uint64 = 0xfec0_0000
        public var LocalApic: uint32 = 0xfee0_0000

        public init(cpus: int) {
            Cpus = cpus
        }
    }

    public struct Arm64 {
        public var Cpus: int
        public var Distributor: uint64
        public var Redistributor: uint64
        public var RedistributorSize: uint32
        public var Its: uint64 = 0
        /// The PPI of the virtual timer's maintenance interrupt, and the
        /// performance monitor's; 0 for none.
        public var MaintenanceIrq: uint32 = 25
        public var PmuIrq: uint32 = 23

        public init(cpus: int, distributor: uint64, redistributor: uint64, redistributorSize: uint32) {
            Cpus = cpus
            Distributor = distributor
            Redistributor = redistributor
            RedistributorSize = redistributorSize
        }
    }

    public static func Build(_ o: Amd64) -> [uint8] {
        var t = Table(signature: "APIC", revision: 5)
        t.U32(o.LocalApic)
        t.U32(0)                                // flags: no 8259 PICs
        for i in 0..<o.Cpus {
            t.U8(0); t.U8(8)                    // Processor Local APIC
            t.U8(uint8(i)); t.U8(uint8(i))      // ACPI processor UID, APIC ID
            t.U32(1)                            // enabled
        }
        t.U8(1); t.U8(12)                       // I/O APIC
        t.U8(0); t.U8(0)                        // ID, reserved
        t.U32(uint32(o.IoApic))
        t.U32(0)                                // global system interrupt base
        return t.Finish()
    }

    public static func Build(_ o: Arm64) -> [uint8] {
        var t = Table(signature: "APIC", revision: 5)
        t.U32(0)                                // no local APIC
        t.U32(0)
        for i in 0..<o.Cpus {
            t.U8(0x0b); t.U8(80)                // GICC
            t.U16(0)
            t.U32(uint32(i))                    // CPU interface number
            t.U32(uint32(i))                    // ACPI processor UID
            t.U32(1)                            // enabled
            t.U32(0)                            // parking protocol version
            t.U32(o.PmuIrq)
            t.U64(0)                            // parked address
            t.U64(0)                            // physical base (GICv3: none)
            t.U64(0); t.U64(0); t.U64(0)        // GICV, GICH, (unused)
            t.U32(o.MaintenanceIrq)
            t.U64(0)                            // GICR base: the GICR structure covers it
            t.U64(uint64(i))                    // MPIDR
            t.U8(0)                             // efficiency class
            t.Zeroes(3)
        }
        t.U8(0x0c); t.U8(24)                    // GICD
        t.U16(0)
        t.U32(0)
        t.U64(o.Distributor)
        t.U32(0)
        t.U8(3)                                 // GIC version 3
        t.Zeroes(3)
        t.U8(0x0e); t.U8(16)                    // GICR range
        t.U16(0)
        t.U64(o.Redistributor)
        t.U32(o.RedistributorSize)
        if o.Its != 0 {
            t.U8(0x0f); t.U8(20)                // ITS
            t.U16(0)
            t.U32(0)                            // ITS ID
            t.U64(o.Its)
            t.U32(0)
        }
        return t.Finish()
    }
}
