package windows

import (
    "fs"
    "vm"
    "vm/boot"
    "vm/disk"
)

public enum WindowsError: Error {
    case firmwareNotFound(string)
    case isoNotFound(string)
    case invalidIso(string)
}

let firmwareSearchPaths = [
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/share/qemu/edk2-aarch64-code.fd",
    "/usr/share/qemu/edk2-aarch64-code.fd",
    "/usr/share/edk2/aarch64/QEMU_EFI.fd",
    "./edk2-aarch64-code.fd"
]

let varsSearchPaths = [
    "/opt/homebrew/share/qemu/edk2-arm-vars.fd",
    "/usr/local/share/qemu/edk2-arm-vars.fd",
    "/usr/share/qemu/edk2-arm-vars.fd",
    "/usr/share/edk2/aarch64/vars-template.fd",
    "./edk2-arm-vars.fd"
]

/// Resolves EDK2 AArch64 UEFI firmware and NVRAM variable template.
public func FindFirmware(customCodePath: string? = nil, customVarsPath: string? = nil) throws -> (code: [uint8], vars: [uint8]) {
    var codeBytes: [uint8]? = nil
    if let p = customCodePath {
        if let f = try? fs.Open(fs.Path(p)) {
            codeBytes = try? f.ReadToEnd()
            try? f.Close()
        }
    }
    if codeBytes == nil {
        for candidate in firmwareSearchPaths {
            if let f = try? fs.Open(fs.Path(candidate)) {
                codeBytes = try? f.ReadToEnd()
                try? f.Close()
                if codeBytes != nil { break }
            }
        }
    }
    guard let code = codeBytes else {
        throw WindowsError.firmwareNotFound("Could not locate edk2-aarch64-code.fd in standard paths")
    }

    var varsBytes: [uint8]? = nil
    if let p = customVarsPath {
        if let f = try? fs.Open(fs.Path(p)) {
            varsBytes = try? f.ReadToEnd()
            try? f.Close()
        }
    }
    if varsBytes == nil {
        for candidate in varsSearchPaths {
            if let f = try? fs.Open(fs.Path(candidate)) {
                varsBytes = try? f.ReadToEnd()
                try? f.Close()
                if varsBytes != nil { break }
            }
        }
    }
    let vars = varsBytes ?? [uint8](repeating: 0xff, count: 64 << 20)

    return (code: code, vars: vars)
}

/// Automatically creates a complete VM configuration tailored for Windows ARM64.
public func ConfigureVm(
    isoPath: string,
    vcpus: int = 4,
    memoryMiB: int = 4096,
    targetDisk: (any disk.Image)? = nil,
    customCodePath: string? = nil,
    customVarsPath: string? = nil
) async throws -> vm.Config {
    let p = fs.Path(isoPath)
    guard let isoDisk = try? await vm.OpenDisk(p, readOnly: true) else {
        throw WindowsError.isoNotFound("Could not open ISO disk at \(isoPath)")
    }

    let fw = try FindFirmware(customCodePath: customCodePath, customVarsPath: customVarsPath)

    var cfg = vm.Config(
        cpus: max(2, vcpus),
        memory: uint64(memoryMiB) << 20
    )
    cfg.Profile = .standard
    cfg.Guest = .windows
    cfg.Display = vm.DisplayRole.custom(width: 1024, height: 768)
    cfg.Boot = .efi(firmware: fw.code, vars: fw.vars)

    // Attach installation media
    cfg.Storage.append(.installer(isoDisk))

    // Attach target disk if provided
    if let target = targetDisk {
        cfg.Storage.append(.disk(target))
    }

    // No network: Windows has no inbox driver for virtio-net.
    // TODO: an e1000e or another NIC Windows drives inbox.

    return cfg
}
