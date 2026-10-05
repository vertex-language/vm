package boot

import "encoding/binary"

// The x86 Linux boot protocol (Documentation/arch/x86/boot.rst), for
// kernels without a PVH note: setup_header at 0x1f1, the protected-mode
// kernel after the setup sectors, and boot_params (the "zero page") that
// the VMM fills: e820 map, cmdline pointer, ramdisk address and size.

let hdrSMagic: uint32 = 0x5372_6448   // "HdrS" at 0x202

public struct SetupHeader {
    public let SetupSectors: int
    public let Version: uint16
    public let LoadFlags: uint8
    public let Code32Start: uint32
    public let InitrdAddrMax: uint32
    public let KernelAlignment: uint32
    public let RelocatableKernel: bool
    public let CmdlineSize: uint32
    public let PrefAddress: uint64
}

public func ParseSetupHeader(_ k: [uint8]) throws -> SetupHeader {
    if k.count < 0x268 || binary.LittleEndian.Uint32(k, from: 0x202) != hdrSMagic {
        throw BootError.badImage("no bzImage HdrS magic")
    }
    let version = binary.LittleEndian.Uint16(k, from: 0x206)
    if version < 0x020c {
        throw BootError.unsupported("boot protocol \(version >> 8).\(version & 0xff); 2.12 or later needed")
    }
    var sects = int(k[0x1f1])
    if sects == 0 { sects = 4 }
    return SetupHeader(
        SetupSectors: sects,
        Version: version,
        LoadFlags: k[0x211],
        Code32Start: binary.LittleEndian.Uint32(k, from: 0x214),
        InitrdAddrMax: binary.LittleEndian.Uint32(k, from: 0x22c),
        KernelAlignment: binary.LittleEndian.Uint32(k, from: 0x230),
        RelocatableKernel: k[0x234] != 0,
        CmdlineSize: binary.LittleEndian.Uint32(k, from: 0x238),
        PrefAddress: binary.LittleEndian.Uint64(k, from: 0x258)
    )
}

/// Plans a 64-bit boot of a bzImage.
///
/// TODO(P2, amd64): boot_params at 0x7000 with the setup header copied in,
/// type_of_loader 0xff, e820 entries, cmd_line_ptr, ramdisk_image/size;
/// identity-mapped page tables for the first 4 GiB at 0x9000; entry at
/// the protected-mode kernel + 0x200 (startup_64).
public func BzImage(kernel: [uint8], initrd: [uint8]?, cmdline: string) throws -> Plan {
    _ = try ParseSetupHeader(kernel)
    throw BootError.unsupported("bzImage boot is not written yet; use a PVH vmlinux")
}
