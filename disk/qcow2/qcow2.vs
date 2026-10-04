// Package qcow2 reads and writes QCOW2 images (versions 2 and 3):
// sparse, copy-on-write, with an optional read-only backing image.
package qcow2

import (
    "compress/flate"
    "encoding/binary"
    "fs"
    "vm/disk"
)

// An L1/L2 entry's host offset, and its flags.
let offsetMask: uint64 = 0x00ff_ffff_ffff_fe00
let copiedFlag: uint64 = 1 << 63
let compressedFlag: uint64 = 1 << 62
let zeroFlag: uint64 = 1 << 0

/// An open QCOW2 image.
public final class Image: disk.Image {
    let file: fs.File
    public let Header: Header
    public let ReadOnly: bool
    /// The image unallocated clusters read through to, if any.
    public let Backing: (any disk.Image)?
    var l1: [uint64]
    /// Recently used L2 tables, by host offset.
    var l2Cache: [uint64: [uint64]] = [:]
    /// Where the next new cluster goes: the end of the file.
    var nextCluster: uint64

    public var Size: uint64 { Header.Size }

    init(file: fs.File, header: Header, l1: [uint64], backing: (any disk.Image)?, readOnly: bool, end: uint64) {
        self.file = file
        Header = header
        self.l1 = l1
        Backing = backing
        ReadOnly = readOnly
        nextCluster = (end + header.ClusterSize - 1) / header.ClusterSize * header.ClusterSize
    }

    /// Where a guest offset's bytes live: a host offset, zeroes, or the
    /// backing image.
    enum Location {
        case host(uint64)
        /// A deflated cluster: where it starts, how many bytes it takes,
        /// and where in the inflated cluster the wanted byte is.
        case compressed(start: uint64, size: uint64, within: uint64)
        case zero
        case backing
    }

    func locate(_ offset: uint64) throws -> Location {
        let cs = Header.ClusterSize
        let l2Index = (offset / cs) % Header.L2Entries
        let l1Index = offset / cs / Header.L2Entries
        if l1Index >= uint64(l1.count) {
            throw disk.DiskError.outOfRange(offset: offset, count: 1)
        }
        let l2Offset = l1[int(l1Index)] & offsetMask
        if l2Offset == 0 {
            return Backing != nil ? .backing : .zero
        }
        let entry = try l2Table(at: l2Offset)[int(l2Index)]
        if entry & compressedFlag != 0 {
            // The low 62 - (clusterBits - 8) bits are the byte offset, the
            // next clusterBits - 8 the count of further 512-byte sectors.
            let sectorBits = uint64(Header.ClusterBits) - 8
            let offsetBits = 62 - sectorBits
            let start = entry & ((1 << offsetBits) - 1)
            let sectors = ((entry >> offsetBits) & ((1 << sectorBits) - 1)) + 1
            return .compressed(start: start, size: sectors * 512 - (start & 511), within: offset % cs)
        }
        if Header.Version == 3 && entry & zeroFlag != 0 {
            return .zero
        }
        let host = entry & offsetMask
        if host == 0 {
            return Backing != nil ? .backing : .zero
        }
        return .host(host + offset % cs)
    }

    func l2Table(at hostOffset: uint64) throws -> [uint64] {
        if let t = l2Cache[hostOffset] {
            return t
        }
        var raw = [uint8](repeating: 0, count: int(Header.ClusterSize))
        _ = try file.Read(into: &raw, at: int64(hostOffset))
        var t = [uint64](repeating: 0, count: int(Header.L2Entries))
        for i in 0..<t.count {
            t[i] = binary.BigEndian.Uint64(raw, from: i * 8)
        }
        if l2Cache.count >= 64 {
            l2Cache = [:]   // TODO: LRU
        }
        l2Cache[hostOffset] = t
        return t
    }

    /// One deflated cluster, whole: raw DEFLATE, padded with zeros if the
    /// image's writer left the tail unsaid.
    func inflateCluster(start: uint64, size: uint64) throws -> [uint8] {
        var raw = [uint8](repeating: 0, count: int(size))
        let got = try file.Read(into: &raw, at: int64(start))
        var out = try flate.Decompress(got == raw.count ? raw : Array(raw[0..<got]))
        let cs = int(Header.ClusterSize)
        if out.count < cs {
            out.append(contentsOf: [uint8](repeating: 0, count: cs - out.count))
        }
        return out
    }

    /// Whether anything is stored for the cluster holding `offset`: data
    /// of its own, a deflated cluster, or (with a backing image) whatever
    /// the backing holds. A cluster that is not reads as zeros, so a copy
    /// can skip it without reading.
    public func IsAllocated(_ offset: uint64) throws -> bool {
        switch try locate(offset) {
        case .zero: return false
        default: return true
        }
    }

    /// ReadAt without `async`, for an image with no backing file: a copy
    /// loop that needn't suspend can be an ordinary function.
    public func ReadSync(_ offset: uint64, into buffer: inout [uint8]) throws {
        try disk.CheckRange(self, offset, uint64(buffer.count))
        let cs = Header.ClusterSize
        var done: uint64 = 0
        let total = uint64(buffer.count)
        while done < total {
            let at = offset + done
            let n = int(min(cs - at % cs, total - done))
            let from = int(done)
            switch try locate(at) {
            case .host(let h):
                var chunk = [uint8](repeating: 0, count: n)
                _ = try file.Read(into: &chunk, at: int64(h))
                for i in 0..<n { buffer[from + i] = chunk[i] }
            case .compressed(let start, let size, let within):
                let inflated = try inflateCluster(start: start, size: size)
                for i in 0..<n { buffer[from + i] = inflated[int(within) + i] }
            case .backing:
                throw disk.DiskError.unsupported("ReadSync on an image with a backing file")
            case .zero:
                for i in 0..<n { buffer[from + i] = 0 }
            }
            done += uint64(n)
        }
    }

    public func ReadAt(_ offset: uint64, into buffer: inout [uint8]) async throws {
        try disk.CheckRange(self, offset, uint64(buffer.count))
        let cs = Header.ClusterSize
        var done: uint64 = 0
        let total = uint64(buffer.count)
        while done < total {
            let at = offset + done
            let n = int(min(cs - at % cs, total - done))
            let from = int(done)
            switch try locate(at) {
            case .host(let h):
                var chunk = [uint8](repeating: 0, count: n)
                _ = try file.Read(into: &chunk, at: int64(h))
                for i in 0..<n { buffer[from + i] = chunk[i] }
            case .compressed(let start, let size, let within):
                let inflated = try inflateCluster(start: start, size: size)
                for i in 0..<n { buffer[from + i] = inflated[int(within) + i] }
            case .backing:
                var chunk = [uint8](repeating: 0, count: n)
                try await Backing!.ReadAt(at, into: &chunk)
                for i in 0..<n { buffer[from + i] = chunk[i] }
            case .zero:
                for i in 0..<n { buffer[from + i] = 0 }
            }
            done += uint64(n)
        }
    }

    public func WriteAt(_ offset: uint64, _ bytes: borrowing [uint8]) async throws {
        if ReadOnly { throw disk.DiskError.readOnly(file.Path.Value) }
        try disk.CheckRange(self, offset, uint64(bytes.count))
        // TODO(P3): allocate L2 tables and data clusters at nextCluster, copy
        // the untouched part of a cluster from Backing, update refcounts,
        // write the data, then the L2 entry, then the L1 entry, in that order.
        throw disk.DiskError.unsupported("QCOW2 writes are not written yet")
    }

    public func Flush() async throws {
        if !ReadOnly {
            try file.Sync()
        }
    }

    public func Discard(_ offset: uint64, count: uint64) async throws {}

    public func Close() {
        try? file.Close()
        Backing?.Close()
    }
}

/// Opens a QCOW2 image. The backing file, if the header names one, is
/// opened read-only by `openBacking`, since only the caller knows where
/// relative names resolve and which formats to allow.
public func Open(_ file: fs.File, readOnly: bool = false,
                 openBacking: ((string) throws -> any disk.Image)? = nil) throws -> Image {
    var head = [uint8](repeating: 0, count: 512)
    _ = try file.Read(into: &head, at: 0)
    let h = try ParseHeader(head)

    var raw = [uint8](repeating: 0, count: int(h.L1Size) * 8)
    _ = try file.Read(into: &raw, at: int64(h.L1TableOffset))
    var l1 = [uint64](repeating: 0, count: int(h.L1Size))
    for i in 0..<l1.count {
        l1[i] = binary.BigEndian.Uint64(raw, from: i * 8)
    }

    var backing: (any disk.Image)? = nil
    if h.BackingFileOffset != 0 {
        var name = [uint8](repeating: 0, count: int(h.BackingFileSize))
        _ = try file.Read(into: &name, at: int64(h.BackingFileOffset))
        guard let open = openBacking else {
            throw disk.DiskError.unsupported("image has a backing file and no way to open it was given")
        }
        backing = try open(string(decoding: name, as: UTF8.self))
    }

    let end = uint64(try file.Metadata().Size)
    return Image(file: file, header: h, l1: l1, backing: backing, readOnly: readOnly, end: end)
}
