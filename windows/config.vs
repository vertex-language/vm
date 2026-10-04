package windows

import (
    "compress/gzip"
    "fs"
    "os/env"
    "os/process"
    "vm"
    "vm/boot"
    "vm/disk"
)

public enum WindowsError: Error {
    case firmwareNotFound(string)
    case isoNotFound(string)
    case invalidIso(string)
}

/// UEFI firmware for a Windows guest: its code, the template its variable
/// store starts from, and what it is.
public struct Firmware {
    public let Code: [uint8]
    public let VarsTemplate: [uint8]
    /// Names the firmware a saved variable store belongs to: a store from
    /// other firmware (without its keys) is not reused.
    public let Name: string
    /// Secure Boot on, with Microsoft's keys enrolled.
    public let SecureBoot: bool
}

/// The Secure Boot firmware in the repository's firmware/ (see its README).
let secureBootCode = "AAVMF_CODE.secboot.fd"
let secureBootVars = "AAVMF_VARS.ms.fd"
let secureBootName = "aavmf-2025.11-3ubuntu7.2-secboot-ms"

/// QEMU's own builds, without Secure Boot: the fallback.
let plainCodePaths = [
    "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
    "/usr/local/share/qemu/edk2-aarch64-code.fd",
    "/usr/share/qemu/edk2-aarch64-code.fd",
    "/usr/share/edk2/aarch64/QEMU_EFI.fd",
]
let plainVarsPaths = [
    "/opt/homebrew/share/qemu/edk2-arm-vars.fd",
    "/usr/local/share/qemu/edk2-arm-vars.fd",
    "/usr/share/qemu/edk2-arm-vars.fd",
    "/usr/share/edk2/aarch64/vars-template.fd",
]

/// Where firmware/ may be: $VERTEX_VM_FIRMWARE, beside the executable (and
/// its parent, for a binary built into the repository root), and here.
func firmwareDirs() -> [string] {
    var dirs: [string] = []
    if let d = env.Get("VERTEX_VM_FIRMWARE") { dirs.append(d) }
    if let exe = process.ExecutablePath(), let dir = fs.Path(exe).Parent() {
        dirs.append(dir.Value + "/firmware")
        if let up = dir.Parent() { dirs.append(up.Value + "/firmware") }
    }
    dirs.append("firmware")
    return dirs
}

/// A file's bytes, or its .gz sibling's, decompressed; nil if neither is there.
func readMaybeGzipped(_ path: string) -> [uint8]? {
    if let f = try? fs.Open(fs.Path(path)) {
        defer { try? f.Close() }
        return try? f.ReadToEnd()
    }
    if let f = try? fs.Open(fs.Path(path + ".gz")) {
        defer { try? f.Close() }
        guard let packed = try? f.ReadToEnd() else { return nil }
        return try? gzip.Decompress(packed, sizeHint: 64 << 20)
    }
    return nil
}

func readFile(_ path: string) -> [uint8]? {
    guard let f = try? fs.Open(fs.Path(path)) else { return nil }
    defer { try? f.Close() }
    return try? f.ReadToEnd()
}

/// Finds UEFI firmware for a Windows guest: `customCodePath` if given (with
/// `customVarsPath` as its template), else the Secure Boot firmware in
/// firmware/, else QEMU's (Secure Boot off).
public func FindFirmware(customCodePath: string? = nil, customVarsPath: string? = nil) throws -> Firmware {
    if let p = customCodePath {
        guard let code = readMaybeGzipped(p) else {
            throw WindowsError.firmwareNotFound("Could not read firmware at \(p)")
        }
        let vars = customVarsPath.flatMap { readMaybeGzipped($0) } ?? [uint8](repeating: 0xff, count: 64 << 20)
        return Firmware(Code: code, VarsTemplate: vars, Name: "custom:" + p, SecureBoot: false)
    }
    for dir in firmwareDirs() {
        if let code = readMaybeGzipped(dir + "/" + secureBootCode),
           let vars = readMaybeGzipped(dir + "/" + secureBootVars) {
            return Firmware(Code: code, VarsTemplate: vars, Name: secureBootName, SecureBoot: true)
        }
    }
    for (i, p) in plainCodePaths.enumerated() {
        if let code = readFile(p) {
            let vars = readFile(plainVarsPaths[i]) ?? [uint8](repeating: 0xff, count: 64 << 20)
            return Firmware(Code: code, VarsTemplate: vars, Name: "qemu-edk2", SecureBoot: false)
        }
    }
    throw WindowsError.firmwareNotFound("No UEFI firmware: put firmware/ beside vm-run, or brew install qemu")
}

/// Automatically creates a complete VM configuration tailored for Windows ARM64.
public func ConfigureVm(
    isoPath: string,
    vcpus: int = 4,
    memoryMiB: int = 4096,
    targetDisk: (any disk.Image)? = nil,
    firmware: Firmware,
    savedVars: [uint8]? = nil,
    tpmStateDir: string? = nil
) async throws -> vm.Config {
    let p = fs.Path(isoPath)
    guard let isoDisk = try? await vm.OpenDisk(p, readOnly: true) else {
        throw WindowsError.isoNotFound("Could not open ISO disk at \(isoPath)")
    }

    var cfg = vm.Config(
        cpus: max(2, vcpus),
        memory: uint64(memoryMiB) << 20
    )
    cfg.Profile = .standard
    cfg.Guest = .windows
    cfg.Display = vm.DisplayRole.custom(width: 1024, height: 768)
    // A variable store saved from an earlier boot, or the firmware's own.
    cfg.Boot = .efi(firmware: firmware.Code, vars: savedVars ?? firmware.VarsTemplate)

    // A TPM 2.0, which Windows 11 requires.
    if let dir = tpmStateDir {
        cfg.Tpm = .swtpm(stateDir: dir)
    }

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
