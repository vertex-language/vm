package boot

import (
    "compress/gzip"
    "encoding/binary"
    "fs"
    "os/process"
)

/// The detected format of an ARM64 Linux kernel image.
public enum KernelFormat: Equatable, CustomStringConvertible {
    case rawArm64
    case gzip
    case efiZboot(compression: string)
    case unknown

    public var description: string {
        switch self {
        case .rawArm64:
            return "raw ARM64 Linux Image"
        case .gzip:
            return "gzip-compressed Linux Image"
        case .efiZboot(let comp):
            return "EFI zboot Linux executable (\(comp))"
        case .unknown:
            return "unknown kernel format"
        }
    }
}

/// Identifies the packaging format of the given kernel binary bytes.
public func DetectKernelFormat(_ data: [uint8]) -> KernelFormat {
    if data.count >= 64 && binary.LittleEndian.Uint32(data, from: 0x38) == arm64Magic {
        return .rawArm64
    }
    if data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b {
        return .gzip
    }
    // Linux's EFI zboot header is at the start of the file: "MZ", then
    // "zimg", the payload's offset and size, and the compression's name.
    if let comp = zimgCompression(data, at: 0) {
        return .efiZboot(compression: comp)
    }
    if data.count >= 64 && data[0] == 0x4d && data[1] == 0x5a { // "MZ"
        let peOffset = int(binary.LittleEndian.Uint32(data, from: 0x3c))
        if peOffset + 24 <= data.count &&
           data[peOffset] == 0x50 && data[peOffset+1] == 0x45 &&
           data[peOffset+2] == 0 && data[peOffset+3] == 0 {
            let numSections = int(binary.LittleEndian.Uint16(data, from: peOffset + 6))
            let optHdrSize = int(binary.LittleEndian.Uint16(data, from: peOffset + 20))
            let sectTable = peOffset + 24 + optHdrSize
            for i in 0..<numSections {
                let off = sectTable + i * 40
                guard off + 40 <= data.count else { break }
                var nameBytes = [uint8]()
                for j in 0..<8 {
                    let b = data[off + j]
                    if b != 0 { nameBytes.append(b) }
                }
                let name = String(decoding: nameBytes, as: UTF8.self)
                if name == ".linux" {
                    let rawPtr = int(binary.LittleEndian.Uint32(data, from: off + 20))
                    if rawPtr + 28 <= data.count {
                        // Check "zimg" magic
                        if data[rawPtr+4] == 0x7a && data[rawPtr+5] == 0x69 &&
                           data[rawPtr+6] == 0x6d && data[rawPtr+7] == 0x67 {
                            var compBytes = [uint8]()
                            for j in 0..<8 {
                                let b = data[rawPtr + 20 + j]
                                if b != 0 { compBytes.append(b) }
                            }
                            let comp = String(decoding: compBytes, as: UTF8.self)
                            return .efiZboot(compression: comp)
                        }
                    }
                }
            }
        }
    }
    return .unknown
}

/// The compression a zboot header at `base` names ("gzip", "zstd"), or
/// nil where there is no header there.
func zimgCompression(_ data: [uint8], at base: int) -> string? {
    guard base + 0x38 <= data.count, data[base + 4] == 0x7a, data[base + 5] == 0x69,
          data[base + 6] == 0x6d, data[base + 7] == 0x67 else { return nil }
    var comp = [uint8]()
    for j in 0..<32 {
        let b = data[base + 0x18 + j]
        if b == 0 { break }
        comp.append(b)
    }
    return String(decoding: comp, as: UTF8.self)
}

/// The Image inside a zboot header at `base`: its payload, decompressed.
func unpackZimg(_ data: [uint8], at base: int, _ comp: string) async throws -> [uint8] {
    let start = base + int(binary.LittleEndian.Uint32(data, from: base + 8))
    let end = start + int(binary.LittleEndian.Uint32(data, from: base + 12))
    guard start < end && end <= data.count else {
        throw BootError.badImage("corrupted EFI zboot payload offsets")
    }
    let payload = [uint8](data[start..<end])
    var decomp: [uint8]
    if comp == "gzip" {
        decomp = try gzip.Decompress(payload)
    } else if comp == "zstd" {
        decomp = try await decompressZstd(payload)
    } else {
        throw BootError.unsupported("EFI zboot compression algorithm '\(comp)'")
    }
    if decomp.count >= 64 && binary.LittleEndian.Uint32(decomp, from: 0x38) == arm64Magic {
        return decomp
    }
    throw BootError.badImage("decompressed EFI zboot payload does not contain ARM64 Image magic")
}

func findZstdExecutable() -> string {
    let candidates = [
        "/opt/homebrew/bin/zstd",
        "/usr/local/bin/zstd",
        "/usr/bin/zstd",
        "zstd"
    ]
    for p in candidates {
        if (try? fs.Metadata(fs.Path(p))) != nil {
            return p
        }
    }
    return "zstd"
}

func decompressZstd(_ compressed: [uint8]) async throws -> [uint8] {
    let zstdBin = findZstdExecutable()
    var cmd = process.Command(zstdBin, ["-d", "-q"])
    cmd.Stdin = .pipe
    cmd.Stdout = .pipe
    let child = try cmd.Spawn()
    Task {
        try? await child.Stdin!.Write(compressed)
        child.Stdin!.Close()
    }
    let decompressed = try await child.Stdout!.ReadToEnd(limit: 256 * 1024 * 1024)
    let status = try await child.Wait()
    if !status.Success {
        throw BootError.badImage("zstd decompression failed (status \(status))")
    }
    return decompressed
}

/// Unpacks any compressed or wrapped Linux kernel into a raw ARM64 Image binary.
/// If the kernel is already a raw ARM64 Image, it is returned without modification.
public func UnpackKernel(_ data: [uint8]) async throws -> [uint8] {
    let fmt = DetectKernelFormat(data)
    switch fmt {
    case .rawArm64:
        return data

    case .gzip:
        let decomp = try gzip.Decompress(data)
        if decomp.count >= 64 && binary.LittleEndian.Uint32(decomp, from: 0x38) == arm64Magic {
            return decomp
        }
        throw BootError.badImage("decompressed gzip payload does not contain ARM64 Image magic")

    case .efiZboot(let comp):
        if zimgCompression(data, at: 0) != nil {
            return try await unpackZimg(data, at: 0, comp)
        }
        let peOffset = int(binary.LittleEndian.Uint32(data, from: 0x3c))
        let numSections = int(binary.LittleEndian.Uint16(data, from: peOffset + 6))
        let optHdrSize = int(binary.LittleEndian.Uint16(data, from: peOffset + 20))
        let sectTable = peOffset + 24 + optHdrSize
        for i in 0..<numSections {
            let off = sectTable + i * 40
            guard off + 40 <= data.count else { break }
            var nameBytes = [uint8]()
            for j in 0..<8 {
                let b = data[off + j]
                if b != 0 { nameBytes.append(b) }
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if name == ".linux" {
                let rawPtr = int(binary.LittleEndian.Uint32(data, from: off + 20))
                let payloadOff = int(binary.LittleEndian.Uint32(data, from: rawPtr + 8))
                let payloadLen = int(binary.LittleEndian.Uint32(data, from: rawPtr + 12))
                let start = rawPtr + payloadOff
                let end = start + payloadLen
                guard start < end && end <= data.count else {
                    throw BootError.badImage("corrupted EFI zboot section offsets")
                }
                let payload = [uint8](data[start..<end])
                var decomp: [uint8]
                if comp == "gzip" {
                    decomp = try gzip.Decompress(payload)
                } else if comp == "zstd" {
                    decomp = try await decompressZstd(payload)
                } else {
                    throw BootError.unsupported("EFI zboot compression algorithm '\(comp)'")
                }

                if decomp.count >= 64 && binary.LittleEndian.Uint32(decomp, from: 0x38) == arm64Magic {
                    return decomp
                }
                throw BootError.badImage("decompressed EFI zboot payload does not contain ARM64 Image magic")
            }
        }
        throw BootError.badImage("failed to locate .linux section in EFI zboot executable")

    case .unknown:
        // If ARM64 magic is present despite unknown format, allow raw boot
        if data.count >= 64 && binary.LittleEndian.Uint32(data, from: 0x38) == arm64Magic {
            return data
        }
        throw BootError.badImage("unrecognized kernel format or missing ARM64 Image header")
    }
}
