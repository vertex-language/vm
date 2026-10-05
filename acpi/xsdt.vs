package acpi

/// The Extended System Description Table: the addresses of every other
/// table (except the DSDT and FACS, which the FADT points at).
public func Xsdt(_ tables: [uint64]) -> [uint8] {
    var t = Table(signature: "XSDT", revision: 1)
    for a in tables {
        t.U64(a)
    }
    return t.Finish()
}
