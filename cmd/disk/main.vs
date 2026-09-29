package main

import (
    "fs"
    "os/process"
    "vm"
    "vm/disk"
    "vm/disk/qcow2"
)

func printUsage() {
    print("""
Usage: disk <command> [arguments]

Commands:
  info <path>                   Show disk image information
  create <path> <size>          Create a new raw disk image (e.g., 10G, 512M)
  convert <source> <dest>       Convert / copy a disk image to a raw image
""")
}

func parseSize(_ str: string) -> uint64? {
    let bytes = [uint8](str.utf8)
    if bytes.isEmpty { return nil }
    var val: uint64 = 0
    var multiplier: uint64 = 1
    var hasDigits = false

    for b in bytes {
        if b >= 48 && b <= 57 { // '0'..'9'
            val = val * 10 + uint64(b - 48)
            hasDigits = true
        } else if b == 71 || b == 103 { // 'G', 'g'
            multiplier = 1024 * 1024 * 1024
        } else if b == 77 || b == 109 { // 'M', 'm'
            multiplier = 1024 * 1024
        } else if b == 75 || b == 107 { // 'K', 'k'
            multiplier = 1024
        }
    }
    if !hasDigits || val == 0 { return nil }
    return val * multiplier
}

func formatSize(_ bytes: uint64) -> string {
    let gib = bytes / (1024 * 1024 * 1024)
    if gib > 0 {
        let remMib = (bytes % (1024 * 1024 * 1024)) / (1024 * 1024)
        return "\(gib).\(remMib * 10 / 1024) GiB (\(bytes) bytes)"
    }
    let mib = bytes / (1024 * 1024)
    if mib > 0 {
        let remKib = (bytes % (1024 * 1024)) / 1024
        return "\(mib).\(remKib * 10 / 1024) MiB (\(bytes) bytes)"
    }
    let kib = bytes / 1024
    if kib > 0 {
        return "\(kib) KiB (\(bytes) bytes)"
    }
    return "\(bytes) bytes"
}

func doInfo(_ pathStr: string) async throws {
    let p = fs.Path(pathStr)
    let img = try await vm.OpenDisk(p)
    defer { img.Close() }

    print("Image path:     \(pathStr)")
    print("Virtual size:   \(formatSize(img.Size))")
    print("Read only:      \(img.ReadOnly)")

    // Inspect header for format details
    var magic = [uint8](repeating: 0, count: 512)
    if let f = try? fs.Open(p) {
        defer { try? f.Close() }
        _ = try? f.Read(into: &magic, at: 0)
    }

    if magic.count >= 4 && magic[0] == 0x51 && magic[1] == 0x46 && magic[2] == 0x49 && magic[3] == 0xfb {
        print("Format:         QCOW2")
        if let hdr = try? qcow2.ParseHeader(magic) {
            print("QCOW2 version:  \(hdr.Version)")
            print("Cluster size:   \(hdr.ClusterSize) bytes")
            print("L1 table size:  \(hdr.L1Size) entries")
        }
    } else {
        let magicStr = string(decoding: magic, as: UTF8.self)
        if magicStr.starts(with: "vhdx") {
            print("Format:         VHDX")
        } else {
            print("Format:         Raw")
        }
    }
}

func doCreate(_ pathStr: string, _ sizeStr: string) throws {
    guard let size = parseSize(sizeStr) else {
        print("Error: Invalid size format '\(sizeStr)'. Example: 10G, 512M")
        return
    }
    let p = fs.Path(pathStr)
    _ = try disk.CreateRaw(p, size: size)
    print("Created raw disk image at \(pathStr) (\(formatSize(size)))")
}

func doConvert(_ srcStr: string, _ dstStr: string) async throws {
    let srcPath = fs.Path(srcStr)
    let dstPath = fs.Path(dstStr)

    print("Opening source disk: \(srcStr)...")
    let src = try await vm.OpenDisk(srcPath, readOnly: true)
    defer { src.Close() }

    let size = src.Size
    print("Source virtual size: \(formatSize(size))")
    print("Creating destination raw disk: \(dstStr)...")
    let dst = try disk.CreateRaw(dstPath, size: size)
    defer { dst.Close() }

    let chunkSize: uint64 = 1024 * 1024 // 1 MB
    var offset: uint64 = 0
    var buf = [uint8](repeating: 0, count: int(chunkSize))

    while offset < size {
        let toRead = (offset + chunkSize <= size) ? chunkSize : (size - offset)
        if buf.count != int(toRead) {
            buf = [uint8](repeating: 0, count: int(toRead))
        }
        try await src.ReadAt(offset, into: &buf)
        try await dst.WriteAt(offset, buf)
        offset += toRead
    }
    try await dst.Flush()
    print("Conversion complete: \(dstStr) written successfully.")
}

public func main() async throws {
    let args = process.Args
    if args.count < 2 {
        printUsage()
        return
    }

    let cmd = args[1]
    switch cmd {
    case "info":
        if args.count < 3 {
            print("Usage: disk info <path>")
            return
        }
        try await doInfo(args[2])

    case "create":
        if args.count < 4 {
            print("Usage: disk create <path> <size>")
            return
        }
        try doCreate(args[2], args[3])

    case "convert":
        if args.count < 4 {
            print("Usage: disk convert <source> <dest>")
            return
        }
        try await doConvert(args[2], args[3])

    case "--help", "-h", "help":
        printUsage()

    default:
        print("Unknown command: \(cmd)")
        printUsage()
    }
}
