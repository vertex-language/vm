package qcow2

import "encoding/binary"
import "vm/disk"

let magic: uint32 = 0x514649fb    // "QFI\xfb"

/// The QCOW2 header: the fields of version 2, and the version 3 extras.
public struct Header {
    public var Version: uint32
    public var BackingFileOffset: uint64
    public var BackingFileSize: uint32
    public var ClusterBits: uint32
    /// The virtual disk's size in bytes.
    public var Size: uint64
    public var CryptMethod: uint32
    public var L1Size: uint32
    public var L1TableOffset: uint64
    public var RefcountTableOffset: uint64
    public var RefcountTableClusters: uint32
    public var SnapshotCount: uint32
    public var SnapshotsOffset: uint64
    // Version 3.
    public var IncompatibleFeatures: uint64 = 0
    public var CompatibleFeatures: uint64 = 0
    public var AutoclearFeatures: uint64 = 0
    public var RefcountOrder: uint32 = 4
    public var HeaderLength: uint32 = 72

    public var ClusterSize: uint64 { 1 << uint64(ClusterBits) }
    /// How many 8-byte entries an L2 table holds.
    public var L2Entries: uint64 { ClusterSize / 8 }
}

/// Incompatible feature bits this package understands. Any other set bit
/// means the image can't be opened safely.
let incompatibleDirty: uint64 = 1 << 0
let incompatibleCorrupt: uint64 = 1 << 1
let incompatibleExternalData: uint64 = 1 << 2
let incompatibleCompression: uint64 = 1 << 3
let incompatibleExtendedL2: uint64 = 1 << 4

/// Parses a header from the first bytes of an image.
public func ParseHeader(_ b: [uint8]) throws -> Header {
    if b.count < 72 || binary.BigEndian.Uint32(b, from: 0) != magic {
        throw disk.DiskError.badFormat("no QCOW2 magic")
    }
    var h = Header(
        Version: binary.BigEndian.Uint32(b, from: 4),
        BackingFileOffset: binary.BigEndian.Uint64(b, from: 8),
        BackingFileSize: binary.BigEndian.Uint32(b, from: 16),
        ClusterBits: binary.BigEndian.Uint32(b, from: 20),
        Size: binary.BigEndian.Uint64(b, from: 24),
        CryptMethod: binary.BigEndian.Uint32(b, from: 32),
        L1Size: binary.BigEndian.Uint32(b, from: 36),
        L1TableOffset: binary.BigEndian.Uint64(b, from: 40),
        RefcountTableOffset: binary.BigEndian.Uint64(b, from: 48),
        RefcountTableClusters: binary.BigEndian.Uint32(b, from: 56),
        SnapshotCount: binary.BigEndian.Uint32(b, from: 60),
        SnapshotsOffset: binary.BigEndian.Uint64(b, from: 64)
    )
    if h.Version != 2 && h.Version != 3 {
        throw disk.DiskError.unsupported("QCOW2 version \(h.Version)")
    }
    if h.ClusterBits < 9 || h.ClusterBits > 21 {
        throw disk.DiskError.corrupt("cluster bits \(h.ClusterBits)")
    }
    if h.CryptMethod != 0 {
        throw disk.DiskError.unsupported("encrypted QCOW2")
    }
    if h.Version == 3 {
        if b.count < 104 {
            throw disk.DiskError.corrupt("short version 3 header")
        }
        h.IncompatibleFeatures = binary.BigEndian.Uint64(b, from: 72)
        h.CompatibleFeatures = binary.BigEndian.Uint64(b, from: 80)
        h.AutoclearFeatures = binary.BigEndian.Uint64(b, from: 88)
        h.RefcountOrder = binary.BigEndian.Uint32(b, from: 96)
        h.HeaderLength = binary.BigEndian.Uint32(b, from: 100)
        let known = incompatibleDirty | incompatibleCorrupt
        if h.IncompatibleFeatures & ~known != 0 {
            throw disk.DiskError.unsupported("QCOW2 incompatible features 0x\(string(h.IncompatibleFeatures, radix: 16))")
        }
        if h.IncompatibleFeatures & incompatibleCorrupt != 0 {
            throw disk.DiskError.corrupt("image is marked corrupt")
        }
    }
    return h
}
