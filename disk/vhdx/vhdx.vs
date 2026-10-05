// Package vhdx reads and writes VHDX images: the format Hyper-V uses, and
// the one Windows images and Windows' own tools produce.
//
// [MS-VHDX]: a file type identifier, two headers (the current one has the
// higher sequence number), a region table naming the BAT and the metadata
// region, and a log to replay before trusting either.
package vhdx

import (
    "encoding/binary"
    "fs"
    "vm/disk"
)

let fileSignature: uint64 = 0x656c_6966_7864_6876    // "vhdxfile"
let headerSignature: uint32 = 0x64616568             // "head"
let regionSignature: uint32 = 0x69676572             // "regi"

/// The parts of the metadata region this package needs.
public struct Metadata {
    public var BlockSize: uint32
    public var LogicalSectorSize: uint32
    public var PhysicalSectorSize: uint32
    public var VirtualDiskSize: uint64
    /// A differencing disk reads unallocated blocks from its parent.
    public var HasParent: bool
}

/// An open VHDX image.
public final class Image: disk.Image {
    let file: fs.File
    public let Metadata: Metadata
    public let ReadOnly: bool
    /// The block allocation table: one entry per payload block, with
    /// sector bitmap entries interleaved every chunk ratio.
    var bat: [uint64]

    public var Size: uint64 { Metadata.VirtualDiskSize }

    init(file: fs.File, metadata: Metadata, bat: [uint64], readOnly: bool) {
        self.file = file
        self.Metadata = metadata
        self.bat = bat
        ReadOnly = readOnly
    }

    public func ReadAt(_ offset: uint64, into buffer: inout [uint8]) async throws {
        try disk.CheckRange(self, offset, uint64(buffer.count))
        // TODO(P5): map offset → payload block → BAT entry (state in the low
        // 3 bits, file offset in MB in the top 44), read or zero-fill.
        throw disk.DiskError.unsupported("VHDX reads are not written yet")
    }

    public func WriteAt(_ offset: uint64, _ bytes: borrowing [uint8]) async throws {
        if ReadOnly { throw disk.DiskError.readOnly(file.Path.Value) }
        throw disk.DiskError.unsupported("VHDX writes are not written yet")
    }

    public func Flush() async throws {
        if !ReadOnly {
            try file.Sync()
        }
    }

    public func Discard(_ offset: uint64, count: uint64) async throws {}

    public func Close() {
        try? file.Close()
    }
}

/// Opens a VHDX image.
public func Open(_ file: fs.File, readOnly: bool = false) throws -> Image {
    var ident = [uint8](repeating: 0, count: 8)
    _ = try file.Read(into: &ident, at: 0)
    if binary.LittleEndian.Uint64(ident, from: 0) != fileSignature {
        throw disk.DiskError.badFormat("no VHDX file identifier")
    }
    // TODO(P5): read both headers at 64 KiB and 128 KiB, pick the valid one
    // with the higher SequenceNumber (CRC-32C checked), replay its log if
    // LogGuid isn't zero, then read the region table at 192 KiB for the BAT
    // and metadata regions.
    throw disk.DiskError.unsupported("VHDX is not written yet")
}

/// Creates a dynamic VHDX of `size` bytes.
public func Create(_ path: fs.Path, size: uint64, blockSize: uint32 = 32 << 20) throws -> Image {
    throw disk.DiskError.unsupported("creating VHDX is not written yet")
}
