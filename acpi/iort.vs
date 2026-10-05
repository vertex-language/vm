package acpi

/// The IO Remapping Table (arm64): how PCI requester IDs reach the ITS,
/// which Windows on ARM needs for MSIs. One ITS group and one root complex
/// node with an identity ID mapping.
public func Iort(itsId: uint32 = 0, pciSegment: uint32 = 0) -> [uint8] {
    var t = Table(signature: "IORT", revision: 3)
    // TODO(P5): header (node count 2, node offset 48), an ITS group node,
    // and a root complex node mapping IDs 0..0xffff onto the ITS.
    t.U32(0)                                    // number of nodes
    t.U32(48)                                   // offset to the node array
    t.U32(0)
    return t.Finish()
}
