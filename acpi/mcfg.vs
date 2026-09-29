package acpi

/// The PCI Express memory-mapped configuration table: where ECAM is.
public func Mcfg(ecam: uint64, segment: uint16 = 0, startBus: uint8 = 0, endBus: uint8 = 0) -> [uint8] {
    var t = Table(signature: "MCFG", revision: 1)
    t.Zeroes(8)
    t.U64(ecam)
    t.U16(segment)
    t.U8(startBus)
    t.U8(endBus)
    t.U32(0)
    return t.Finish()
}
