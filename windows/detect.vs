package windows

import (
    "fs"
    "vm/disk"
)

public struct WindowsIsoInfo {
    public let Path: string
    public let VolumeId: string
    public let Arch: string
    public let Edition: string
    public let IsArm64: bool

    public init(path: string, volumeId: string, arch: string, edition: string, isArm64: bool) {
        self.Path = path
        self.VolumeId = volumeId
        self.Arch = arch
        self.Edition = edition
        self.IsArm64 = isArm64
    }
}

/// Detects whether an ISO image at the given path is a Windows ARM64 installation media.
public func DetectIso(_ path: string) throws -> WindowsIsoInfo? {
    let p = fs.Path(path)
    guard let file = try? fs.Open(p) else { return nil }
    defer { try? file.Close() }

    guard let iso = try? disk.ReadIsoInfo(from: file) else { return nil }

    let vid = iso.VolumeId
    let isWindows = vid.contains("CCCOMA") || vid.contains("WIN") || vid.contains("DV9") || vid.contains("MICROSOFT")
    if !isWindows {
        return nil
    }

    let isArm64 = vid.contains("A64") || vid.contains("ARM64") || vid.contains("arm64")
    let arch = isArm64 ? "arm64" : "x86_64"
    let edition = isArm64 ? "Windows 11 ARM64 Client" : "Windows Client"

    return WindowsIsoInfo(
        path: path,
        volumeId: iso.VolumeId,
        arch: arch,
        edition: edition,
        isArm64: isArm64
    )
}
