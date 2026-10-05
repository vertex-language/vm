package boot

import (
    "encoding/binary"
    "vm/device"
)

// PVH direct boot: the x86 entry Firecracker, Cloud Hypervisor and QEMU's
// microvm converged on. An ELF kernel (Linux vmlinux, FreeBSD) names a
// 32-bit entry point in a Xen ELF note; the VMM enters it in protected mode
// with paging off and ebx pointing at an hvm_start_info.

let xenNotePhys32Entry: uint32 = 18   // XEN_ELFNOTE_PHYS32_ENTRY
let startInfoMagic: uint32 = 0x336e_c578

/// Where PVH's small structures go, below the kernel's 1 MiB.
public let PvhStartInfo: uint64 = 0x6000
public let PvhMemoryMap: uint64 = 0x7000
public let PvhCmdline: uint64 = 0x2_0000

/// The entry point the kernel's PVH note names, or nil if it has none.
public func PvhEntry(_ elf: Elf) -> uint64? {
    for n in elf.Notes() where n.name == "Xen" && n.type == xenNotePhys32Entry {
        if n.desc.count >= 8 {
            return binary.LittleEndian.Uint64(n.desc, from: 0)
        }
        if n.desc.count >= 4 {
            return uint64(binary.LittleEndian.Uint32(n.desc, from: 0))
        }
    }
    return nil
}

/// One entry of the memory map PVH hands the kernel (e820 types).
public struct MemoryMapEntry {
    public let Address: uint64
    public let Size: uint64
    /// 1 RAM, 2 reserved, 3 ACPI reclaimable.
    public let Type: uint32
}

/// Plans a PVH boot. The start_info, its memory map, the command line and
/// the initrd's module entry are all in the plan; vm only sets registers.
public func Pvh(kernel: [uint8], initrd: [uint8]?, cmdline: string,
                memoryMap: [MemoryMapEntry], rsdp: uint64, initrdAt: uint64) throws -> Plan {
    let elf = try ParseElf(kernel)
    guard let entry = PvhEntry(elf) else {
        throw BootError.unsupported("kernel has no PVH entry note (build with CONFIG_PVH)")
    }
    var p = Plan()
    p.Cmdline = cmdline
    p.Loads.append(contentsOf: elf.Loads())

    var line = Array(cmdline.utf8)
    line.append(0)
    p.Loads.append(Load(Address: device.GuestAddress(PvhCmdline), Bytes: line))

    var mmap: [uint8] = []
    for e in memoryMap {
        binary.LittleEndian.AppendUint64(&mmap, e.Address)
        binary.LittleEndian.AppendUint64(&mmap, e.Size)
        binary.LittleEndian.AppendUint32(&mmap, e.Type)
        binary.LittleEndian.AppendUint32(&mmap, 0)
    }
    p.Loads.append(Load(Address: device.GuestAddress(PvhMemoryMap), Bytes: mmap))

    var modules: uint64 = 0
    var moduleCount: uint32 = 0
    if let rd = initrd {
        p.Loads.append(Load(Address: device.GuestAddress(initrdAt), Bytes: rd))
        p.Initrd = device.Range(base: initrdAt, count: uint64(rd.count))
        var m: [uint8] = []
        binary.LittleEndian.AppendUint64(&m, initrdAt)
        binary.LittleEndian.AppendUint64(&m, uint64(rd.count))
        binary.LittleEndian.AppendUint64(&m, 0)   // cmdline
        binary.LittleEndian.AppendUint64(&m, 0)
        modules = PvhStartInfo + 0x100
        moduleCount = 1
        p.Loads.append(Load(Address: device.GuestAddress(modules), Bytes: m))
    }

    // struct hvm_start_info, version 1.
    var si: [uint8] = []
    binary.LittleEndian.AppendUint32(&si, startInfoMagic)
    binary.LittleEndian.AppendUint32(&si, 1)                  // version
    binary.LittleEndian.AppendUint32(&si, 0)                  // flags
    binary.LittleEndian.AppendUint32(&si, moduleCount)
    binary.LittleEndian.AppendUint64(&si, modules)
    binary.LittleEndian.AppendUint64(&si, PvhCmdline)
    binary.LittleEndian.AppendUint64(&si, rsdp)
    binary.LittleEndian.AppendUint64(&si, PvhMemoryMap)
    binary.LittleEndian.AppendUint32(&si, uint32(memoryMap.count))
    binary.LittleEndian.AppendUint32(&si, 0)
    p.Loads.append(Load(Address: device.GuestAddress(PvhStartInfo), Bytes: si))

    p.Entry = .pvh(eip: entry, startInfo: PvhStartInfo)
    return p
}
