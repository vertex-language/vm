package boot

import (
    "vm/device"
    "vm/disk"
)

/// UEFI firmware: a code image the guest runs from its reset vector, and a
/// variable store it writes boot entries and Secure Boot keys into.
///
/// The firmware is a guest artifact the user supplies, like a kernel; it's
/// never in this repository. Stock EDK2 builds (OVMF for amd64,
/// ArmVirtQemu for arm64: what distributions and Homebrew ship) expect
/// two CFI flash banks and fw_cfg, which is what this plans for.
public struct Efi {
    /// The firmware code, mapped read-only.
    public let Code: [uint8]
    /// The variable store: a file that persists between boots.
    public let Vars: any disk.Image

    public init(code: [uint8], vars: any disk.Image) {
        Code = code
        Vars = vars
    }
}

/// Where the flash banks sit. arm64 `virt`-style: code at 0, vars at 64 MiB,
/// 64 MiB each. amd64: code ends at 4 GiB, vars just below it.
public struct FlashLayout {
    public let Code: device.Range
    public let Vars: device.Range

    public static let arm64 = FlashLayout(
        Code: device.Range(base: 0x0000_0000, count: 64 << 20),
        Vars: device.Range(base: 0x0400_0000, count: 64 << 20)
    )

    public static func amd64(codeSize: uint64, varsSize: uint64) -> FlashLayout {
        let codeBase = (uint64(1) << 32) - codeSize
        return FlashLayout(
            Code: device.Range(base: codeBase, count: codeSize),
            Vars: device.Range(base: codeBase - varsSize, count: varsSize)
        )
    }
}

/// Plans a firmware boot: the vCPU starts at its architectural reset
/// vector, which the flash banks cover.
public func EfiBoot(_ efi: Efi, layout: FlashLayout) throws -> Plan {
    if uint64(efi.Code.count) > layout.Code.Count {
        throw BootError.tooBig("firmware code is \(efi.Code.count) bytes; the bank holds \(layout.Code.Count)")
    }
    var p = Plan()
    p.Entry = .reset
    return p
}
