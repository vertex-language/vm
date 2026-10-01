package windows

import (
    "encoding/binary"
)

/// QemuLoaderCmd: command types for QEMU's ACPI table loader interface.
public enum LoaderCommandType: uint32 {
    case allocate     = 1
    case addPointer   = 2
    case addChecksum  = 3
    case writePointer = 4
}

/// TableLoader builds the 128-byte packed commands for the "etc/table-loader" fw_cfg file.
/// EDK2's QemuFwCfgAcpiPlatformDxe parses these commands to download, link, and install ACPI tables.
public struct TableLoader {
    public private(set) var Bytes: [uint8] = []

    public init() {}

    /// QemuLoaderCmdAllocate: allocate memory in guest zone and download file from fw_cfg.
    public mutating func Allocate(file: string, align: uint32 = 64, zone: uint8 = 1) {
        var entry = [uint8](repeating: 0, count: 128)
        binary.LittleEndian.PutUint32(&entry, LoaderCommandType.allocate.rawValue, at: 0)
        writeFileName(&entry, at: 4, file)
        binary.LittleEndian.PutUint32(&entry, align, at: 60)
        entry[64] = zone
        Bytes.append(contentsOf: entry)
    }

    /// QemuLoaderCmdAddPointer: add base address of srcFile to the pointer at destOffset in destFile.
    public mutating func AddPointer(destFile: string, destOffset: uint32, size: uint8, srcFile: string) {
        var entry = [uint8](repeating: 0, count: 128)
        binary.LittleEndian.PutUint32(&entry, LoaderCommandType.addPointer.rawValue, at: 0)
        writeFileName(&entry, at: 4, destFile)
        writeFileName(&entry, at: 60, srcFile)
        binary.LittleEndian.PutUint32(&entry, destOffset, at: 116)
        entry[120] = size
        Bytes.append(contentsOf: entry)
    }

    /// QemuLoaderCmdAddChecksum: compute 8-bit checksum of range and store at resultOffset.
    public mutating func AddChecksum(file: string, resultOffset: uint32, start: uint32, length: uint32) {
        var entry = [uint8](repeating: 0, count: 128)
        binary.LittleEndian.PutUint32(&entry, LoaderCommandType.addChecksum.rawValue, at: 0)
        writeFileName(&entry, at: 4, file)
        binary.LittleEndian.PutUint32(&entry, resultOffset, at: 60)
        binary.LittleEndian.PutUint32(&entry, start, at: 64)
        binary.LittleEndian.PutUint32(&entry, length, at: 68)
        Bytes.append(contentsOf: entry)
    }

    /// QemuLoaderCmdWritePointer: write patched pointer back to fw_cfg.
    public mutating func WritePointer(destFile: string, destOffset: uint32, size: uint8, srcFile: string, srcOffset: uint32) {
        var entry = [uint8](repeating: 0, count: 128)
        binary.LittleEndian.PutUint32(&entry, LoaderCommandType.writePointer.rawValue, at: 0)
        writeFileName(&entry, at: 4, destFile)
        writeFileName(&entry, at: 60, srcFile)
        binary.LittleEndian.PutUint32(&entry, destOffset, at: 116)
        binary.LittleEndian.PutUint32(&entry, srcOffset, at: 120)
        entry[124] = size
        Bytes.append(contentsOf: entry)
    }
}

func writeFileName(_ buf: inout [uint8], at offset: int, _ name: string) {
    let nameBytes = Array(name.utf8)
    let count = min(nameBytes.count, 55)
    for i in 0..<count {
        buf[offset + i] = nameBytes[i]
    }
    buf[offset + count] = 0
}
