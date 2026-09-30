package disk

import (
    "encoding/binary"
    "fs"
)

/// Standard identifier for ISO 9660 volume descriptors ("CD001").
let isoMagic: [uint8] = [0x43, 0x44, 0x30, 0x30, 0x31]

/// ISO 9660 primary volume descriptor sector offset (Sector 16 * 2048 bytes).
public let IsoPvdOffset: uint64 = 32768
public let IsoSectorSize: uint64 = 2048

/// Metadata parsed from an ISO 9660 Primary Volume Descriptor (ECMA-119).
public struct IsoInfo {
    public let VolumeId: string
    public let SystemId: string
    public let VolumeSpaceSize: uint32
    public let LogicalBlockSize: uint16
    public let Publisher: string
    public let Application: string
    public let IsBootable: bool
    public let RootLba: uint32
    public let RootLength: uint32

    public init(
        volumeId: string,
        systemId: string,
        volumeSpaceSize: uint32,
        logicalBlockSize: uint16,
        publisher: string,
        application: string,
        isBootable: bool = false,
        rootLba: uint32 = 0,
        rootLength: uint32 = 0
    ) {
        VolumeId = volumeId
        SystemId = systemId
        VolumeSpaceSize = volumeSpaceSize
        LogicalBlockSize = logicalBlockSize
        Publisher = publisher
        Application = application
        IsBootable = isBootable
        RootLba = rootLba
        RootLength = rootLength
    }
}

func trimTrailingSpaces(_ bytes: [uint8]) -> string {
    var end = bytes.count
    while end > 0 && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x00) {
        end -= 1
    }
    if end == 0 { return "" }
    return string(decoding: bytes[0..<end], as: UTF8.self)
}

/// Parses an ISO 9660 Primary Volume Descriptor from sector 16 (2048 bytes).
public func ParseIsoPvd(_ b: [uint8]) throws -> IsoInfo {
    if b.count < 2048 {
        throw DiskError.badFormat("buffer too small for ISO 9660 volume descriptor (\(b.count) bytes)")
    }
    // Byte 0: Type code (1 = Primary Volume Descriptor)
    // Bytes 1..5: Standard Identifier ("CD001")
    // Byte 6: Version (1)
    if b[0] != 1 || b[1] != isoMagic[0] || b[2] != isoMagic[1] || b[3] != isoMagic[2] || b[4] != isoMagic[3] || b[5] != isoMagic[4] || b[6] != 1 {
        throw DiskError.badFormat("missing ISO 9660 PVD signature")
    }

    let sysIdBytes = Array(b[8..<40])
    let volIdBytes = Array(b[40..<72])
    let volSpaceSize = binary.LittleEndian.Uint32(b, from: 80)
    let logicalBlockSize = binary.LittleEndian.Uint16(b, from: 128)
    let pubBytes = Array(b[318..<446])
    let appBytes = Array(b[574..<702])

    var rootLba: uint32 = 0
    var rootLength: uint32 = 0
    if b.count >= 190 {
        rootLba = binary.LittleEndian.Uint32(b, from: 156 + 2)
        rootLength = binary.LittleEndian.Uint32(b, from: 156 + 10)
    }

    return IsoInfo(
        volumeId: trimTrailingSpaces(volIdBytes),
        systemId: trimTrailingSpaces(sysIdBytes),
        volumeSpaceSize: volSpaceSize,
        logicalBlockSize: logicalBlockSize,
        publisher: trimTrailingSpaces(pubBytes),
        application: trimTrailingSpaces(appBytes),
        isBootable: false,
        rootLba: rootLba,
        rootLength: rootLength
    )
}

/// Reads ISO 9660 information and scans for El Torito boot record from an open file.
public func ReadIsoInfo(from file: fs.File) throws -> IsoInfo? {
    var pvdBuf = [uint8](repeating: 0, count: 2048)
    let n = try file.Read(into: &pvdBuf, at: int64(IsoPvdOffset))
    if n < 2048 { return nil }

    guard let info = try? ParseIsoPvd(pvdBuf) else { return nil }
    var isBootable = false

    // Scan subsequent sectors (17..24) for Boot Record (El Torito)
    var secBuf = [uint8](repeating: 0, count: 2048)
    var sector: uint64 = 17
    while sector <= 24 {
        let readN = try? file.Read(into: &secBuf, at: int64(sector * IsoSectorSize))
        if let r = readN, r >= 2048 {
            let typeCode = secBuf[0]
            if typeCode == 255 { // Volume Descriptor Set Terminator
                break
            }
            if typeCode == 0 && secBuf[1] == isoMagic[0] && secBuf[2] == isoMagic[1] && secBuf[3] == isoMagic[2] && secBuf[4] == isoMagic[3] && secBuf[5] == isoMagic[4] {
                // Check if Boot System Identifier starts with "EL TORITO"
                let bootSys = string(decoding: secBuf[7..<39], as: UTF8.self)
                if bootSys.starts(with: "EL TORITO") {
                    isBootable = true
                }
            }
        }
        sector += 1
    }

    return IsoInfo(
        volumeId: info.VolumeId,
        systemId: info.SystemId,
        volumeSpaceSize: info.VolumeSpaceSize,
        logicalBlockSize: info.LogicalBlockSize,
        publisher: info.Publisher,
        application: info.Application,
        isBootable: isBootable,
        rootLba: info.RootLba,
        rootLength: info.RootLength
    )
}

/// Normalizes ISO 9660 identifiers: strips version suffix ';1', trailing dots, and converts to lowercase.
public func NormalizeIsoName(_ bytes: [uint8]) -> string {
    var res: [uint8] = []
    for b in bytes {
        if b == 59 { break } // ";" indicates ISO version suffix
        if b >= 65 && b <= 90 { // ASCII 'A'-'Z'
            res.append(b + 32)
        } else {
            res.append(b)
        }
    }
    if res.count > 0 && res[res.count - 1] == 46 { // trailing dot for extensionless files
        res.removeLast()
    }
    return string(decoding: res, as: UTF8.self)
}

/// An entry (file or subdirectory) in an ISO 9660 filesystem.
public struct IsoEntry: Equatable {
    public let Name: string
    public let RawName: string
    public let Lba: uint32
    public let Size: uint32
    public let IsDirectory: bool

    public init(name: string, rawName: string, lba: uint32, size: uint32, isDirectory: bool) {
        self.Name = name
        self.RawName = rawName
        self.Lba = lba
        self.Size = size
        self.IsDirectory = isDirectory
    }
}

/// Reads all directory entries from an ISO 9660 extent at `lba`.
public func ReadIsoDirectory(from file: fs.File, at lba: uint32, length: uint32) throws -> [IsoEntry] {
    var entries: [IsoEntry] = []
    let sectorCount = (int(length) + 2047) / 2048
    var sectorBuf = [uint8](repeating: 0, count: 2048)

    for s in 0..<sectorCount {
        let secLba = uint64(lba) + uint64(s)
        let n = try file.Read(into: &sectorBuf, at: int64(secLba * IsoSectorSize))
        if n < 2048 { break }

        var pos = 0
        while pos < 2048 {
            let recordLen = int(sectorBuf[pos])
            if recordLen == 0 || pos + recordLen > 2048 || recordLen < 33 {
                break
            }

            let extentLba = binary.LittleEndian.Uint32(sectorBuf, from: pos + 2)
            let dataLength = binary.LittleEndian.Uint32(sectorBuf, from: pos + 10)
            let flags = sectorBuf[pos + 25]
            let isDir = (flags & 0x02) != 0
            let nameLen = int(sectorBuf[pos + 32])

            if pos + 33 + nameLen <= 2048 && nameLen > 0 {
                let nameBytes = Array(sectorBuf[(pos + 33)..<(pos + 33 + nameLen)])
                if nameBytes != [0] && nameBytes != [1] { // Skip . and ..
                    let rawName = string(decoding: nameBytes, as: UTF8.self)
                    let normName = NormalizeIsoName(nameBytes)
                    entries.append(IsoEntry(name: normName, rawName: rawName, lba: extentLba, size: dataLength, isDirectory: isDir))
                }
            }

            pos += recordLen
        }
    }

    return entries
}

/// Finds a file or directory entry by hierarchical path (e.g. "casper/vmlinuz" or "linux").
public func FindIsoEntry(from file: fs.File, rootLba: uint32, rootLength: uint32, path: string) throws -> IsoEntry? {
    var cleanPath = path
    if cleanPath.starts(with: "/") {
        cleanPath = String(cleanPath.dropFirst())
    }
    if cleanPath.isEmpty { return nil }

    var components: [string] = []
    var current: [uint8] = []
    for b in [uint8](cleanPath.utf8) {
        if b == 47 { // "/"
            if !current.isEmpty {
                components.append(NormalizeIsoName(current))
                current = []
            }
        } else {
            current.append(b)
        }
    }
    if !current.isEmpty {
        components.append(NormalizeIsoName(current))
    }
    if components.isEmpty { return nil }

    var currentLba = rootLba
    var currentLen = rootLength

    for i in 0..<components.count {
        let comp = components[i]
        let isLast = (i == components.count - 1)
        let entries = try ReadIsoDirectory(from: file, at: currentLba, length: currentLen)
        var found: IsoEntry? = nil
        for e in entries {
            if e.Name == comp {
                found = e
                break
            }
        }
        guard let match = found else { return nil }
        if isLast { return match }
        if !match.IsDirectory { return nil }
        currentLba = match.Lba
        currentLen = match.Size
    }

    return nil
}

/// Boot files detected within an ISO installer distribution.
public struct IsoBootFiles {
    public let Kernel: IsoEntry
    public let Initrd: IsoEntry?
    public let KernelPath: string
    public let InitrdPath: string?
    public let RecommendedCmdline: string

    public init(kernel: IsoEntry, initrd: IsoEntry?, kernelPath: string, initrdPath: string?, recommendedCmdline: string) {
        self.Kernel = kernel
        self.Initrd = initrd
        self.KernelPath = kernelPath
        self.InitrdPath = initrdPath
        self.RecommendedCmdline = recommendedCmdline
    }
}

/// Automatically scans well-known distribution paths in an ISO image to detect kernel and initrd.
public func FindIsoBootFiles(from file: fs.File, rootLba: uint32, rootLength: uint32) throws -> IsoBootFiles? {
    // 1. Ubuntu / Casper live desktop or server
    if let k = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "casper/vmlinuz") {
        let rd = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "casper/initrd")
            ?? (try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "casper/initrd.lz"))
            ?? (try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "casper/initrd.gz"))
        return IsoBootFiles(
            kernel: k,
            initrd: rd,
            kernelPath: "casper/vmlinuz",
            initrdPath: rd != nil ? "casper/initrd" : nil,
            recommendedCmdline: "console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 boot=casper panic=-1 systemd.mask=NetworkManager-wait-online.service"
        )
    }

    // 2. Debian ARM64 official installer
    if let k = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "install.a64/vmlinuz") {
        let rd = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "install.a64/initrd.gz")
        return IsoBootFiles(
            kernel: k,
            initrd: rd,
            kernelPath: "install.a64/vmlinuz",
            initrdPath: rd != nil ? "install.a64/initrd.gz" : nil,
            recommendedCmdline: "console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 panic=-1"
        )
    }

    // 3. Debian netboot / mini ISO ("linux" + "initrd.gz")
    if let k = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "linux") {
        let rd = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "initrd.gz")
            ?? (try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "initrd"))
        return IsoBootFiles(
            kernel: k,
            initrd: rd,
            kernelPath: "linux",
            initrdPath: rd != nil ? "initrd.gz" : nil,
            recommendedCmdline: "console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 panic=-1"
        )
    }

    // 4. Arch Linux / generic ("boot/vmlinuz" or "boot/vmlinuz-linux")
    if let k = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "boot/vmlinuz") {
        let rd = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "boot/initrd.img")
            ?? (try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "boot/initramfs-linux.img"))
        return IsoBootFiles(
            kernel: k,
            initrd: rd,
            kernelPath: "boot/vmlinuz",
            initrdPath: rd != nil ? "boot/initrd.img" : nil,
            recommendedCmdline: "console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 panic=-1"
        )
    }

    // 5. Fedora / RHEL ("images/pxeboot/vmlinuz")
    if let k = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "images/pxeboot/vmlinuz") {
        let rd = try FindIsoEntry(from: file, rootLba: rootLba, rootLength: rootLength, path: "images/pxeboot/initrd.img")
        return IsoBootFiles(
            kernel: k,
            initrd: rd,
            kernelPath: "images/pxeboot/vmlinuz",
            initrdPath: rd != nil ? "images/pxeboot/initrd.img" : nil,
            recommendedCmdline: "console=tty0 console=ttyAMA0 earlycon=pl011,0x09000000 panic=-1"
        )
    }

    return nil
}

/// Reads file bytes for an ISO entry in 4 MB chunks.
public func ReadIsoFile(from file: fs.File, entry: IsoEntry) throws -> [uint8] {
    let totalSize = int64(entry.Size)
    var result = [uint8](repeating: 0, count: int(totalSize))
    let chunkSize = 4 * 1024 * 1024
    var chunk = [uint8](repeating: 0, count: chunkSize)
    var offset: int64 = 0
    let startOffset = int64(uint64(entry.Lba) * IsoSectorSize)

    while offset < totalSize {
        let toRead = min(int64(chunkSize), totalSize - offset)
        let n = try file.Read(into: &chunk, at: startOffset + offset)
        if n <= 0 { break }
        let toCopy = min(n, int(toRead))
        for j in 0..<toCopy {
            result[int(offset) + j] = chunk[j]
        }
        offset += int64(toCopy)
    }
    return result
}

/// Extracts an ISO entry to a local destination file path in 4 MB chunks.
public func ExtractIsoFile(from file: fs.File, entry: IsoEntry, to destination: fs.Path) throws {
    let destFile = try fs.Create(destination)
    let totalSize = int64(entry.Size)
    let chunkSize = 4 * 1024 * 1024
    var chunk = [uint8](repeating: 0, count: chunkSize)
    var offset: int64 = 0
    let startOffset = int64(uint64(entry.Lba) * IsoSectorSize)

    while offset < totalSize {
        let toRead = min(int64(chunkSize), totalSize - offset)
        let n = try file.Read(into: &chunk, at: startOffset + offset)
        if n <= 0 { break }
        let toCopy = min(n, int(toRead))
        try destFile.Write(Array(chunk[0..<toCopy]), at: offset)
        offset += int64(toCopy)
    }
}
