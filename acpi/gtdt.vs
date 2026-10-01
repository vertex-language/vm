package acpi

/// The Generic Timer Description Table (arm64): which PPIs the
/// architectural timers use. The standard assignment: secure EL1 29,
/// non-secure EL1 30, virtual 27, EL2 26.
public func Gtdt(virtualTimerIrq: uint32 = 27) -> [uint8] {
    var t = Table(signature: "GTDT", revision: 3)
    t.U64(~0)                                   // CntControlBase: none
    t.U32(0)
    t.U32(29); t.U32(0)                         // secure EL1: GSIV, flags
    t.U32(30); t.U32(4)                         // non-secure EL1: always-on
    t.U32(virtualTimerIrq); t.U32(0)            // virtual
    t.U32(26); t.U32(0)                         // EL2
    t.U64(~0)                                   // CntReadBase: none
    t.U32(0)                                    // platform timer count
    t.U32(0)                                    // platform timer offset
    t.U32(0); t.U32(0)                          // virtual EL2 timer (revision 3): none
    return t.Finish()
}
