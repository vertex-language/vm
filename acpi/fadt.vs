package acpi

/// The Fixed ACPI Description Table, hardware-reduced (ACPI 6.x, FADT
/// revision 6): no PM1 blocks, no SCI, no RTC or PM timer ports. On arm64
/// it also says PSCI is how CPUs are started, over HVC.
public struct FadtOptions {
    public var Dsdt: uint64
    public var Arm: bool
    /// SLEEP_CONTROL_REG / SLEEP_STATUS_REG for S5, if the platform has
    /// them (a GED-owned register); 0 for none.
    public var SleepControl: uint64 = 0
    public var ResetRegister: uint64 = 0
    public var ResetValue: uint8 = 1

    public init(dsdt: uint64, arm: bool) {
        Dsdt = dsdt
        Arm = arm
    }
}

public func Fadt(_ o: FadtOptions) -> [uint8] {
    var t = Table(signature: "FACP", revision: 6)
    t.U32(0)                    // FIRMWARE_CTRL
    t.U32(0)                    // DSDT (32-bit): X_DSDT is used
    t.Zeroes(1)                 // reserved
    t.U8(0)                     // preferred PM profile: unspecified
    // Offsets 46–108: SCI_INT through CENTURY, all zero for reduced hardware.
    t.Zeroes(109 - 46)
    t.U16(0)                    // IAPC_BOOT_ARCH: no 8042, no VGA probing
    t.Zeroes(1)                 // reserved (111)
    var flags: uint32 = 1 << 20 // HW_REDUCED_ACPI
    flags |= 1 << 10            // RESET_REG_SUP
    t.U32(flags)
    t.Gas(space: AddressSpace.memory, bitWidth: 8, accessSize: 1, address: o.ResetRegister)
    t.U8(o.ResetValue)
    t.U16(o.Arm ? 0x3 : 0)      // ARM_BOOT_ARCH: PSCI compliant, use HVC
    t.U8(3)                     // FADT minor version
    t.U64(0)                    // X_FIRMWARE_CTRL
    t.U64(o.Dsdt)               // X_DSDT
    t.Zeroes(8 * 12)            // X_PM1a_EVT_BLK … X_GPE1_BLK: eight empty GAS
    t.Gas(space: AddressSpace.memory, bitWidth: 8, accessSize: 1, address: o.SleepControl)
    t.Gas(space: AddressSpace.memory, bitWidth: 8, accessSize: 1, address: o.SleepControl)
    t.U64(0x4d56_5845_5452_4556) // hypervisor vendor identity: "VERTEXVM"
    return t.Finish()
}
