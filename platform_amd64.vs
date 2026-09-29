package vm

public struct PlatformAmd64 {
    public static let LowRamBase: uint64       = 0x0000_0000
    public static let LowRamLimit: uint64      = 0xc000_0000 // 3 GiB
    public static let HighRamBase: uint64      = 0x1_0000_0000 // 4 GiB

    public static let IoApicBase: uint64       = 0xfec0_0000
    public static let LApicBase: uint64        = 0xfee0_0000

    public static let Com1Port: uint16         = 0x3f8
    public static let CmosPort: uint16         = 0x70

    public static let PciEcamBase: uint64      = 0xe000_0000
    public static let PciEcamSize: uint64      = 0x1000_0000
    public static let PciMmio32Base: uint64    = 0xc000_0000
    public static let PciMmio32Size: uint64    = 0x2000_0000
}
