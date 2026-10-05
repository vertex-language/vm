package main

import (
    "fs"
    "os/process"
    "vm"
    "vm/boot"
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
  list-iso <iso> [dir]          List files and directories in an ISO image
  extract <iso> <file> <dest>   Extract a file from an ISO image to local disk
  extract-kernel <iso> [dest]   Extract and unpack boot kernel to a raw ARM64 Image
  boot-files <iso>              Detect bootable kernel and initrd in an ISO image
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

    // Check if ISO 9660
    var isoInfo: disk.IsoInfo? = nil
    if let f = try? fs.Open(p) {
        defer { try? f.Close() }
        if let info = (try? disk.ReadIsoInfo(from: f)) ?? nil {
            isoInfo = info
        }
    }

    if let iso = isoInfo {
        print("Format:         ISO 9660 (CD-ROM / DVD)")
        if !iso.VolumeId.isEmpty {
            print("Volume ID:      \(iso.VolumeId)")
        }
        if !iso.SystemId.isEmpty {
            print("System ID:      \(iso.SystemId)")
        }
        if !iso.Publisher.isEmpty {
            print("Publisher:      \(iso.Publisher)")
        }
        if !iso.Application.isEmpty {
            print("Application:    \(iso.Application)")
        }
        print("Block size:     \(iso.LogicalBlockSize) bytes")
        print("Bootable:       \(iso.IsBootable ? "yes (El Torito)" : "no")")
    } else if magic.count >= 4 && magic[0] == 0x51 && magic[1] == 0x46 && magic[2] == 0x49 && magic[3] == 0xfb {
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

func doListIso(_ pathStr: string, _ subDir: string = "") async throws {
    let p = fs.Path(pathStr)
    let file = try fs.Open(p)
    defer { try? file.Close() }

    guard let info = try disk.ReadIsoInfo(from: file) else {
        print("Error: \(pathStr) is not a valid ISO 9660 image.")
        return
    }

    var targetLba = info.RootLba
    var targetLen = info.RootLength
    var displayDir = "/"
    if !subDir.isEmpty && subDir != "/" {
        displayDir = subDir
        guard let entry = try disk.FindIsoEntry(from: file, rootLba: info.RootLba, rootLength: info.RootLength, path: subDir) else {
            print("Error: Directory '\(subDir)' not found in ISO.")
            return
        }
        if !entry.IsDirectory {
            print("Error: '\(subDir)' is a file, not a directory.")
            return
        }
        targetLba = entry.Lba
        targetLen = entry.Size
    }

    let entries = try disk.ReadIsoDirectory(from: file, at: targetLba, length: targetLen)
    print("Contents of ISO '\(info.VolumeId)' at \(displayDir):")
    print("----------------------------------------------------------------------")
    print("Type  Size          LBA      Name")
    print("----------------------------------------------------------------------")
    for e in entries {
        let typeStr = e.IsDirectory ? "<DIR>" : "     "
        print("\(typeStr) \(e.Size) bytes  (LBA \(e.Lba))  \(e.Name)")
    }
    print("----------------------------------------------------------------------")
    print("Total: \(entries.count) entries")
}

func doExtract(_ isoStr: string, _ entryPath: string, _ destStr: string) async throws {
    let isoFile = try fs.Open(fs.Path(isoStr))
    defer { try? isoFile.Close() }

    guard let info = try disk.ReadIsoInfo(from: isoFile) else {
        print("Error: \(isoStr) is not a valid ISO 9660 image.")
        return
    }

    guard let entry = try disk.FindIsoEntry(from: isoFile, rootLba: info.RootLba, rootLength: info.RootLength, path: entryPath) else {
        print("Error: File '\(entryPath)' not found in ISO.")
        return
    }

    if entry.IsDirectory {
        print("Error: '\(entryPath)' is a directory, not a file.")
        return
    }

    print("Extracting \(entryPath) (\(entry.Size) bytes) to \(destStr)...")
    try disk.ExtractIsoFile(from: isoFile, entry: entry, to: fs.Path(destStr))
    print("Extraction complete: \(destStr)")
}

func doBootFiles(_ isoStr: string) async throws {
    let isoFile = try fs.Open(fs.Path(isoStr))
    defer { try? isoFile.Close() }

    guard let info = try disk.ReadIsoInfo(from: isoFile) else {
        print("Error: \(isoStr) is not a valid ISO 9660 image.")
        return
    }

    guard let boot = try disk.FindIsoBootFiles(from: isoFile, rootLba: info.RootLba, rootLength: info.RootLength) else {
        print("No standard Linux boot files detected in ISO.")
        return
    }

    print("ISO Boot Configuration for: \(info.VolumeId)")
    print("  Kernel:     \(boot.KernelPath) (\(boot.Kernel.Size) bytes, LBA \(boot.Kernel.Lba))")
    if let rd = boot.Initrd {
        print("  Initrd:     \(boot.InitrdPath ?? "") (\(rd.Size) bytes, LBA \(rd.Lba))")
    }
    print("  Cmdline:    \(boot.RecommendedCmdline)")
}

func doExtractKernel(_ isoStr: string, _ destStr: string) async throws {
    let isoFile = try fs.Open(fs.Path(isoStr))
    defer { try? isoFile.Close() }

    guard let info = try disk.ReadIsoInfo(from: isoFile) else {
        print("Error: \(isoStr) is not a valid ISO 9660 image.")
        return
    }

    guard let bootFiles = try disk.FindIsoBootFiles(from: isoFile, rootLba: info.RootLba, rootLength: info.RootLength) else {
        print("No bootable kernel detected in ISO.")
        return
    }

    print("Found kernel: \(bootFiles.KernelPath) (\(bootFiles.Kernel.Size) bytes)")
    print("Reading kernel bytes from ISO...")
    let rawBytes = try disk.ReadIsoFile(from: isoFile, entry: bootFiles.Kernel)
    let fmt = boot.DetectKernelFormat(rawBytes)
    print("Detected kernel format: \(fmt)")
    print("Unpacking to raw ARM64 Image...")
    let unpacked = try await boot.UnpackKernel(rawBytes)

    let outFile = try fs.Create(fs.Path(destStr))
    defer { try? outFile.Close() }
    try outFile.Write(unpacked, at: 0)
    print("Successfully wrote \(unpacked.count) bytes to \(destStr) (ARM64 Image)")
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

    case "list-iso":
        if args.count < 3 {
            print("Usage: disk list-iso <iso-path> [subdir]")
            return
        }
        let subDir = args.count >= 4 ? args[3] : ""
        try await doListIso(args[2], subDir)

    case "extract":
        if args.count < 5 {
            print("Usage: disk extract <iso-path> <file-in-iso> <dest-path>")
            return
        }
        try await doExtract(args[2], args[3], args[4])

    case "extract-kernel":
        if args.count < 3 {
            print("Usage: disk extract-kernel <iso-path> [dest-path]")
            return
        }
        let dest = args.count >= 4 ? args[3] : "Image"
        try await doExtractKernel(args[2], dest)

    case "boot-files":
        if args.count < 3 {
            print("Usage: disk boot-files <iso-path>")
            return
        }
        try await doBootFiles(args[2])

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
