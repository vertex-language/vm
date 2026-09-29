package acpi

/// The Root System Description Pointer (ACPI 2.0+, 36 bytes), pointing at
/// the XSDT. Firmware finds it for the OS; with direct boot, vm tells the
/// kernel where it is.
public func Rsdp(xsdt: uint64) -> [uint8] {
    var b = Array("RSD PTR ".utf8)
    b.append(0)                                   // checksum of the first 20 bytes
    b.append(contentsOf: OemId)
    b.append(2)                                   // revision: 2.0+
    LE.AppendUint32(&b, 0)                        // RSDT: none
    LE.AppendUint32(&b, 36)                       // length
    LE.AppendUint64(&b, xsdt)
    b.append(0)                                   // extended checksum
    b.append(contentsOf: [0, 0, 0])
    b[8] = Checksum(Array(b[0..<20]))
    b[32] = Checksum(b)
    return b
}
