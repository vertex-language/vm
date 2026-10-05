package disk

import (
    "crypto/crc32"
    "crypto/rand"
    "encoding/binary"
)

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

/// A GPT disk put together from other images: each partition's bytes are
/// another image's (a file, a Slice of one, a MemoryImage), and the
/// partition tables, made here, are kept in memory. Partitions start on
/// 1 MiB boundaries; the space between them reads as zeroes, and writes
/// outside the partitions are kept in memory and dropped on Close.
public final class GptDisk: Image {
    struct Part {
        let Image: any Image
        let Offset: uint64
    }

    let parts: [Part]
    /// The protective MBR, primary header and table, and the space up to the first partition.
    var head: [uint8]
    /// The backup table and header, at the end.
    var tail: [uint8]
    public let Size: uint64
    public var ReadOnly: bool { false }

    /// A disk of partitions, in order: each one's GPT name ("vendor") and
    /// what it holds (parallel arrays: vsc_TODO #58). Each is a Linux file
    /// system partition (type 0FC63DAF-8483-4772-8E79-3D69D8477DE4).
    public init(names: [string], images: [any Image]) {
        let align: uint64 = 1 << 20
        var at = align
        var ps: [Part] = []
        for img in images {
            ps.append(Part(Image: img, Offset: at))
            at += (img.Size + align - 1) / align * align
        }
        parts = ps
        let entriesSectors: uint64 = 32
        let sectors = at / 512 + entriesSectors + 1
        Size = sectors * 512
        let last = sectors - 1

        var entries = [uint8](repeating: 0, count: int(entriesSectors * 512))
        let linuxFs: [uint8] = [0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4]
        for i in 0..<min(names.count, images.count) {
            let name = names[i]
            let img = images[i]
            let e = i * 128
            for j in 0..<16 { entries[e + j] = linuxFs[j] }
            let id = guid()
            for j in 0..<16 { entries[e + 16 + j] = id[j] }
            let first = ps[i].Offset / 512
            binary.LittleEndian.PutUint64(&entries, first, at: e + 32)
            binary.LittleEndian.PutUint64(&entries, first + (img.Size + 511) / 512 - 1, at: e + 40)
            let utf16 = binary.EncodeUTF16LE(name)
            for j in 0..<min(utf16.count, 72) { entries[e + 56 + j] = utf16[j] }
        }
        let entriesCrc = crc32.ChecksumIEEE(entries)
        let diskId = guid()
        func header(mine: uint64, other: uint64, table: uint64) -> [uint8] {
            var h = [uint8](repeating: 0, count: 512)
            for (j, c) in "EFI PART".utf8.enumerated() { h[j] = c }
            binary.LittleEndian.PutUint32(&h, 0x0001_0000, at: 8)
            binary.LittleEndian.PutUint32(&h, 92, at: 12)
            binary.LittleEndian.PutUint64(&h, mine, at: 24)
            binary.LittleEndian.PutUint64(&h, other, at: 32)
            binary.LittleEndian.PutUint64(&h, 2 + entriesSectors, at: 40)
            binary.LittleEndian.PutUint64(&h, last - 1 - entriesSectors, at: 48)
            for j in 0..<16 { h[56 + j] = diskId[j] }
            binary.LittleEndian.PutUint64(&h, table, at: 72)
            binary.LittleEndian.PutUint32(&h, 128, at: 80)
            binary.LittleEndian.PutUint32(&h, 128, at: 84)
            binary.LittleEndian.PutUint32(&h, entriesCrc, at: 88)
            binary.LittleEndian.PutUint32(&h, crc32.ChecksumIEEE(Array(h[0..<92])), at: 16)
            return h
        }

        head = [uint8](repeating: 0, count: int(align))
        // The protective MBR: one partition of type 0xEE over the disk.
        head[446 + 1] = 0x00
        head[446 + 2] = 0x02
        head[446 + 4] = 0xEE
        for j in 5..<8 { head[446 + j] = 0xFF }
        binary.LittleEndian.PutUint32(&head, 1, at: 446 + 8)
        binary.LittleEndian.PutUint32(&head, uint32(min(sectors - 1, 0xFFFF_FFFF)), at: 446 + 12)
        head[510] = 0x55
        head[511] = 0xAA
        let primary = header(mine: 1, other: last, table: 2)
        for j in 0..<512 { head[512 + j] = primary[j] }
        for j in 0..<entries.count { head[1024 + j] = entries[j] }
        tail = entries + header(mine: last, other: 1, table: last - entriesSectors)
    }

    public func ReadAt(_ offset: uint64, into buffer: inout [uint8]) async throws {
        try CheckRange(self, offset, uint64(buffer.count))
        var done = 0
        while done < buffer.count {
            let at = offset + uint64(done)
            let (n, piece) = try await read(at, max: buffer.count - done)
            for i in 0..<n { buffer[done + i] = piece.isEmpty ? 0 : piece[i] }
            done += n
        }
    }

    /// Up to `max` bytes at `at`, all from one place: a partition, the head, the tail, or a gap (empty: zeroes).
    func read(_ at: uint64, max: int) async throws -> (int, [uint8]) {
        let tailAt = Size - uint64(tail.count)
        if at < uint64(head.count) {
            let n = min(max, head.count - int(at))
            return (n, Array(head[int(at)..<(int(at) + n)]))
        }
        if at >= tailAt {
            let n = min(max, int(Size - at))
            return (n, Array(tail[int(at - tailAt)..<(int(at - tailAt) + n)]))
        }
        for p in parts {
            if at >= p.Offset && at < p.Offset + p.Image.Size {
                let n = min(max, int(p.Offset + p.Image.Size - at))
                var b = [uint8](repeating: 0, count: n)
                try await p.Image.ReadAt(at - p.Offset, into: &b)
                return (n, b)
            }
        }
        // A gap: up to the next partition or the tail.
        var end = tailAt
        for p in parts where p.Offset > at && p.Offset < end { end = p.Offset }
        return (min(max, int(end - at)), [])
    }

    public func WriteAt(_ offset: uint64, _ bytes: borrowing [uint8]) async throws {
        try CheckRange(self, offset, uint64(bytes.count))
        let tailAt = Size - uint64(tail.count)
        for i in 0..<bytes.count {
            let at = offset + uint64(i)
            if at < uint64(head.count) {
                head[int(at)] = bytes[i]
            } else if at >= tailAt {
                tail[int(at - tailAt)] = bytes[i]
            }
        }
        for p in parts {
            let start = max(offset, p.Offset)
            let end = min(offset + uint64(bytes.count), p.Offset + p.Image.Size)
            if start < end {
                try await p.Image.WriteAt(start - p.Offset, Array(bytes[int(start - offset)..<int(end - offset)]))
            }
        }
    }

    public func Flush() async throws {
        for p in parts { try await p.Image.Flush() }
    }

    public func Discard(_ offset: uint64, count: uint64) async throws {
        for p in parts {
            let start = max(offset, p.Offset)
            let end = min(offset + count, p.Offset + p.Image.Size)
            if start < end { try await p.Image.Discard(start - p.Offset, count: end - start) }
        }
    }

    public func Close() {
        for p in parts { p.Image.Close() }
    }
}

/// A random (version 4) GUID, in GPT's byte order.
func guid() -> [uint8] {
    var g = (try? rand.Bytes(16)) ?? [uint8](repeating: 0x5A, count: 16)
    g[7] = (g[7] & 0x0F) | 0x40
    g[8] = (g[8] & 0x3F) | 0x80
    return g
}
