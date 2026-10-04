package acpi

/// The TPM2 table (TCG ACPI Specification, revision 4): a client-class
/// TPM 2.0 whose start method is "uses the TIS / FIFO interface over MMIO"
/// (6), so there is no control area. The registers' address is in the
/// MSFT0101 device's _CRS in the DSDT.
public func Tpm2Table() -> [uint8] {
    var t = Table(signature: "TPM2", revision: 4)
    t.U16(0)                    // platform class: client
    t.U16(0)                    // reserved
    t.U64(0)                    // address of the CRB control area: none
    t.U32(6)                    // start method: TIS / FIFO over MMIO
    t.Zeroes(12)                // start-method parameters
    return t.Finish()
}
