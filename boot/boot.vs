// Package boot is what gets a guest from reset to its OS: loaders that put
// a kernel straight into guest RAM (arm64 Image, PVH, bzImage), and the
// devices UEFI firmware boots from (pflash, fw_cfg).
//
// Loaders don't touch a vCPU or guest memory. They parse bytes and return a
// Plan (what goes where, and the entry state), which vm carries out. That
// keeps every loader testable in cmd/check.
package boot

import "vm/device"

/// Bytes to copy into guest RAM.
public struct Load {
    public let Address: device.GuestAddress
    public let Bytes: [uint8]
}

/// The CPU state the boot vCPU starts in.
public enum Entry {
    /// arm64 Linux: pc at the image, x0 the device tree (or 0 with ACPI),
    /// x1–x3 zero, EL1h with interrupts masked, MMU and D-cache off.
    case arm64(pc: uint64, x0: uint64)
    /// amd64 PVH: 32-bit protected mode, paging off, ebx = start_info.
    case pvh(eip: uint64, startInfo: uint64)
    /// amd64 Linux 64-bit boot protocol: long mode with identity-mapped
    /// page tables, rsi = boot_params.
    case linux64(rip: uint64, bootParams: uint64, pageTables: uint64)
    /// Firmware: the reset vector, where the CPU starts anyway.
    case reset
}

/// Where vm should put what it generates, and everything else a kernel
/// needs from the platform.
public struct Plan {
    public var Loads: [Load] = []
    public var Entry: Entry = .reset
    /// Where the platform description goes (FDT on arm64, start_info or
    /// boot_params already filled on amd64). vm writes it before start.
    public var DeviceTree: device.GuestAddress? = nil
    public var Initrd: device.Range? = nil
    public var Cmdline: string = ""
}

/// BootError is a kernel or firmware image this package can't boot.
public enum BootError: Error, CustomStringConvertible {
    case badImage(string)
    case unsupported(string)
    case tooBig(string)

    public var description: string {
        switch self {
        case .badImage(let what):
            return "not a bootable image: \(what)"
        case .unsupported(let what):
            return "unsupported: \(what)"
        case .tooBig(let what):
            return "doesn't fit in guest RAM: \(what)"
        }
    }
}

func alignUp(_ v: uint64, _ a: uint64) -> uint64 {
    (v + a - 1) / a * a
}
