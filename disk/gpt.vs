package disk

import "encoding/binary"

/// A partition of a GPT disk.
public struct Partition {
    /// The partition's name, as GPT stores it (UTF-16): "system", "vendor".
    public let Name: string
    /// Where it starts, and how long it is, in bytes.
    public let Offset: uint64
    public let Size: uint64
}

/// The partitions of a GPT disk (UEFI spec §5.3), in table order; empty
/// when `image` has no GPT. The primary header at LBA 1 is read; 512-byte
/// sectors.
public func Partitions(_ image: any Image) async throws -> [Partition] {
    if image.Size < 34 * 512 { return [] }
    var hdr = [uint8](repeating: 0, count: 92)
    try await image.ReadAt(512, into: &hdr)
    if string(decoding: Array(hdr[0..<8]), as: UTF8.self) != "EFI PART" { return [] }
    let tableLba = binary.LittleEndian.Uint64(hdr, from: 72)
    let count = int(binary.LittleEndian.Uint32(hdr, from: 80))
    let entrySize = int(binary.LittleEndian.Uint32(hdr, from: 84))
    if entrySize < 128 || count > 1024 { return [] }
    var table = [uint8](repeating: 0, count: count * entrySize)
    try await image.ReadAt(tableLba * 512, into: &table)
    var out: [Partition] = []
    for i in 0..<count {
        let e = i * entrySize
        if table[e..<(e + 16)].allSatisfy({ $0 == 0 }) { continue }   // unused entry
        let first = binary.LittleEndian.Uint64(table, from: e + 32)
        let last = binary.LittleEndian.Uint64(table, from: e + 40)
        if last < first || (last + 1) * 512 > image.Size { continue }
        var units: [uint16] = []
        var j = e + 56
        while j + 1 < e + 128 {
            let u = binary.LittleEndian.Uint16(table, from: j)
            if u == 0 { break }
            units.append(u)
            j += 2
        }
        // Names are UTF-16; the ones that matter here are ASCII.
        let name = string(decoding: units.map { $0 < 0x80 ? uint8($0) : uint8(0x3f) }, as: UTF8.self)
        out.append(Partition(Name: name, Offset: first * 512, Size: (last - first + 1) * 512))
    }
    return out
}

/// A window onto part of another image: a partition presented as a whole
/// disk. Reads and writes are bounded to the window.
public final class Slice: Image {
    public let Base: any Image
    public let Offset: uint64
    public let Size: uint64
    public var ReadOnly: bool { Base.ReadOnly }

    public init(_ base: any Image, offset: uint64, size: uint64) {
        Base = base
        Offset = offset
        Size = size
    }

    /// The partition `p` of `base`.
    public convenience init(_ base: any Image, _ p: Partition) {
        self.init(base, offset: p.Offset, size: p.Size)
    }

    public func ReadAt(_ offset: uint64, into buffer: inout [uint8]) async throws {
        try CheckRange(self, offset, uint64(buffer.count))
        try await Base.ReadAt(Offset + offset, into: &buffer)
    }

    public func WriteAt(_ offset: uint64, _ bytes: borrowing [uint8]) async throws {
        try CheckRange(self, offset, uint64(bytes.count))
        try await Base.WriteAt(Offset + offset, bytes)
    }

    public func Flush() async throws {
        try await Base.Flush()
    }

    public func Discard(_ offset: uint64, count: uint64) async throws {
        try CheckRange(self, offset, count)
        try await Base.Discard(Offset + offset, count: count)
    }

    public func Close() {
        Base.Close()
    }
}
