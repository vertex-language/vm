package qcow2

// Writing: new images, clusters written in place or allocated at the end
// of the file, deflated clusters, and the refcounts that say which host
// clusters are in use. Refcounts are 16 bits (refcount order 4); the
// refcount table is the one cluster Create makes, which covers 16 TiB of
// host file at 64 KiB clusters.

import (
    "compress/flate"
    "encoding/binary"
    "fs"
    "vm/disk"
)

/// Makes a QCOW2 image (version 3) at `path` of `size` bytes, every
/// cluster unallocated, and opens it for writing. `clusterBits` is 16
/// (64 KiB clusters), as qemu-img makes them, unless given. With
/// `backing`, unallocated clusters read through to that image (a name
/// `openBacking` resolves, as Open's does): the new image is a
/// copy-on-write overlay of it.
public func Create(_ path: fs.Path, size: uint64, clusterBits: uint32 = 16, backing: string? = nil,
                   openBacking: ((string) throws -> any disk.Image)? = nil) throws -> Image {
    if clusterBits < 9 || clusterBits > 21 { throw disk.DiskError.unsupported("cluster bits \(clusterBits)") }
    let cs = uint64(1) << uint64(clusterBits)
    let l2Entries = cs / 8
    let l1Size = max(uint64(1), (size + cs * l2Entries - 1) / (cs * l2Entries))
    let l1Clusters = (l1Size * 8 + cs - 1) / cs
    // Cluster 0 the header, 1 the refcount table, 2 its first block, then the L1 table.
    let refcountTable = cs
    let refcountBlock = 2 * cs
    let l1Table = 3 * cs
    let used = 3 + l1Clusters

    var head = [uint8](repeating: 0, count: int(cs))
    binary.BigEndian.PutUint32(&head, magic, at: 0)
    binary.BigEndian.PutUint32(&head, 3, at: 4)
    binary.BigEndian.PutUint32(&head, clusterBits, at: 20)
    binary.BigEndian.PutUint64(&head, size, at: 24)
    binary.BigEndian.PutUint32(&head, uint32(l1Size), at: 36)
    binary.BigEndian.PutUint64(&head, l1Table, at: 40)
    binary.BigEndian.PutUint64(&head, refcountTable, at: 48)
    binary.BigEndian.PutUint32(&head, 1, at: 56)
    binary.BigEndian.PutUint32(&head, 4, at: 96)        // refcount order: 16-bit counts
    binary.BigEndian.PutUint32(&head, 104, at: 100)     // header length; the extensions' end marker follows
    if let name = backing {
        // The name after the (empty) extension area: 104 + an 8-byte end marker.
        let bytes = [uint8](name.utf8)
        if 112 + bytes.count > int(cs) || bytes.count > 1023 { throw disk.DiskError.unsupported("backing file name too long") }
        for i in 0..<bytes.count { head[112 + i] = bytes[i] }
        binary.BigEndian.PutUint64(&head, 112, at: 8)
        binary.BigEndian.PutUint32(&head, uint32(bytes.count), at: 16)
    }

    var table = [uint8](repeating: 0, count: int(cs))
    binary.BigEndian.PutUint64(&table, refcountBlock, at: 0)
    var block = [uint8](repeating: 0, count: int(cs))
    for c in 0..<int(used) { binary.BigEndian.PutUint16(&block, 1, at: c * 2) }

    let f = try fs.Create(path)
    try f.SetLength(0)
    try f.Write(head, at: 0)
    try f.Write(table, at: int64(refcountTable))
    try f.Write(block, at: int64(refcountBlock))
    try f.SetLength(int64(used * cs))
    try f.Close()

    let opened = try fs.Open(path, { var o = fs.OpenOptions(); o.Read = true; o.Write = true; return o }())
    return try Open(opened, openBacking: openBacking)
}

extension Image {
    var refcountsPerBlock: uint64 { Header.ClusterSize / 2 }

    /// Reads the refcount table, for an image opened for writing.
    func loadRefcounts() throws {
        if Header.Version == 3 && Header.RefcountOrder != 4 {
            throw disk.DiskError.unsupported("QCOW2 refcounts of \(1 << Header.RefcountOrder) bits")
        }
        let n = int(Header.RefcountTableClusters) * int(Header.ClusterSize) / 8
        var raw = [uint8](repeating: 0, count: n * 8)
        _ = try file.Read(into: &raw, at: int64(Header.RefcountTableOffset))
        refcountTable = [uint64](repeating: 0, count: n)
        for i in 0..<n { refcountTable[i] = binary.BigEndian.Uint64(raw, from: i * 8) & offsetMask }
    }

    func refcountBlock(at hostOffset: uint64) throws -> [uint16] {
        if let b = refcountBlocks[hostOffset] { return b }
        var raw = [uint8](repeating: 0, count: int(Header.ClusterSize))
        _ = try file.Read(into: &raw, at: int64(hostOffset))
        var b = [uint16](repeating: 0, count: int(refcountsPerBlock))
        for i in 0..<b.count { b[i] = binary.BigEndian.Uint16(raw, from: i * 2) }
        refcountBlocks[hostOffset] = b
        return b
    }

    /// A new refcount block for table slot `index`, at the end of the file;
    /// it counts itself where it covers itself.
    func makeRefcountBlock(_ index: int) throws {
        let at = nextCluster
        nextCluster += Header.ClusterSize
        try file.Write([uint8](repeating: 0, count: int(Header.ClusterSize)), at: int64(at))
        refcountBlocks[at] = [uint16](repeating: 0, count: int(refcountsPerBlock))
        refcountTable[index] = at
        var entry = [uint8](repeating: 0, count: 8)
        binary.BigEndian.PutUint64(&entry, at, at: 0)
        try file.Write(entry, at: int64(Header.RefcountTableOffset) + int64(index * 8))
        try addRef(at, 1)
    }

    /// Adds `delta` to the refcount of the host cluster at `hostOffset`,
    /// making its refcount block if it has none.
    func addRef(_ hostOffset: uint64, _ delta: int) throws {
        let cluster = hostOffset / Header.ClusterSize
        let index = int(cluster / refcountsPerBlock)
        if index >= refcountTable.count { throw disk.DiskError.unsupported("QCOW2 image larger than its refcount table covers") }
        if refcountTable[index] == 0 { try makeRefcountBlock(index) }
        let blockAt = refcountTable[index]
        var b = try refcountBlock(at: blockAt)
        let i = int(cluster % refcountsPerBlock)
        let v = int(b[i]) + delta
        if v < 0 || v > 0xFFFF { throw disk.DiskError.corrupt("refcount of cluster \(cluster) would be \(v)") }
        b[i] = uint16(v)
        refcountBlocks[blockAt] = b
        var two = [uint8](repeating: 0, count: 2)
        binary.BigEndian.PutUint16(&two, uint16(v), at: 0)
        try file.Write(two, at: int64(blockAt) + int64(i * 2))
    }

    /// Makes the refcount blocks that will count host clusters up to `end`
    /// first, so clusters allocated after this run on without a block
    /// landing between them.
    func reserveContiguous(through end: uint64) throws {
        while true {
            let before = nextCluster
            var c = nextCluster
            while c < max(end, nextCluster + 1) + Header.ClusterSize {
                let index = int(c / Header.ClusterSize / refcountsPerBlock)
                if index < refcountTable.count && refcountTable[index] == 0 {
                    try makeRefcountBlock(index)
                }
                c += Header.ClusterSize
            }
            if nextCluster == before { return }
        }
    }

    /// A new host cluster at the end of the file, counted.
    func allocate() throws -> uint64 {
        let at = nextCluster
        nextCluster += Header.ClusterSize
        try file.SetLength(int64(nextCluster))
        try addRef(at, 1)
        return at
    }

    /// The L2 table for guest `offset`, made if there is none: its host offset.
    func l2For(_ offset: uint64) throws -> uint64 {
        let l1Index = int(offset / Header.ClusterSize / Header.L2Entries)
        let existing = l1[l1Index] & offsetMask
        if existing != 0 { return existing }
        let at = try allocate()
        try file.Write([uint8](repeating: 0, count: int(Header.ClusterSize)), at: int64(at))
        l2Cache[at] = [uint64](repeating: 0, count: int(Header.L2Entries))
        l1[l1Index] = at | copiedFlag
        var entry = [uint8](repeating: 0, count: 8)
        binary.BigEndian.PutUint64(&entry, l1[l1Index], at: 0)
        try file.Write(entry, at: int64(Header.L1TableOffset) + int64(l1Index * 8))
        return at
    }

    /// Points guest cluster `offset`'s L2 entry at `entry`, freeing what it pointed at.
    func setL2(_ offset: uint64, _ entry: uint64) throws {
        let l2 = try l2For(offset)
        let index = int((offset / Header.ClusterSize) % Header.L2Entries)
        var t = try l2Table(at: l2)
        let old = t[index]
        t[index] = entry
        l2Cache[l2] = t
        var raw = [uint8](repeating: 0, count: 8)
        binary.BigEndian.PutUint64(&raw, entry, at: 0)
        try file.Write(raw, at: int64(l2) + int64(index * 8))
        try release(old)
    }

    /// Drops the references an old L2 entry held.
    func release(_ entry: uint64) throws {
        if entry & compressedFlag != 0 {
            let sectorBits = uint64(Header.ClusterBits) - 8
            let offsetBits = 62 - sectorBits
            let start = entry & ((1 << offsetBits) - 1)
            let sectors = ((entry >> offsetBits) & ((1 << sectorBits) - 1)) + 1
            let end = (start & ~511) + sectors * 512
            var c = start / Header.ClusterSize * Header.ClusterSize
            while c < end {
                try addRef(c, -1)
                c += Header.ClusterSize
            }
            return
        }
        let host = entry & offsetMask
        if host != 0 { try addRef(host, -1) }
    }

    /// Guest cluster `start`'s bytes as they read now, unless they come from
    /// the backing image (nil: the caller reads those).
    func clusterContents(_ start: uint64) throws -> [uint8]? {
        let cs = int(Header.ClusterSize)
        switch try locate(start) {
        case .host(let h):
            var b = [uint8](repeating: 0, count: cs)
            _ = try file.Read(into: &b, at: int64(h))
            return b
        case .compressed(let s, let size, _):
            return try inflateCluster(start: s, size: size)
        case .zero:
            return [uint8](repeating: 0, count: cs)
        case .backing:
            return nil
        }
    }

    /// Writes `bytes` at guest `offset`, a cluster at a time: in place where
    /// the cluster is this image's own and uncompressed, else into a new
    /// cluster holding the old contents with the new bytes over them.
    func write(_ offset: uint64, _ bytes: borrowing [uint8]) throws {
        let cs = Header.ClusterSize
        var done: uint64 = 0
        let total = uint64(bytes.count)
        while done < total {
            let at = offset + done
            let within = at % cs
            let n = min(cs - within, total - done)
            let start = at - within
            var piece = [uint8](repeating: 0, count: int(n))
            for i in 0..<int(n) { piece[i] = bytes[int(done) + i] }
            if case .host(let h) = try locate(at) {
                try file.Write(piece, at: int64(h))
            } else {
                if n == cs {
                    try storeCluster(start, piece)
                } else {
                    guard var cluster = try clusterContents(start) else {
                        throw disk.DiskError.unsupported("part of a cluster the backing image holds: WriteAt reads it first")
                    }
                    for i in 0..<int(n) { cluster[int(within) + i] = piece[i] }
                    try storeCluster(start, cluster)
                }
            }
            done += n
        }
    }

    /// A whole cluster's new contents, in a new host cluster.
    func storeCluster(_ start: uint64, _ cluster: [uint8]) throws {
        let host = try allocate()
        try file.Write(cluster, at: int64(host))
        try setL2(start, host | copiedFlag)
    }

    /// Writes one whole guest cluster deflated, as `qemu-img convert -c`
    /// does: `offset` is cluster-aligned and `cluster` a cluster's bytes.
    /// Deflated clusters are packed one after another, 512-byte aligned
    /// within the host clusters they share; one that doesn't shrink is
    /// written as it is.
    public func WriteCompressed(_ offset: uint64, _ cluster: [uint8]) throws {
        if ReadOnly { throw disk.DiskError.readOnly(file.Path.Value) }
        let cs = Header.ClusterSize
        if offset % cs != 0 || uint64(cluster.count) != cs { throw disk.DiskError.unsupported("WriteCompressed takes one whole, aligned cluster") }
        try disk.CheckRange(self, offset, cs)
        let deflated = flate.Compress(cluster)
        let len = uint64(deflated.count)
        if len >= cs - 512 {
            try storeCluster(offset, cluster)
            return
        }
        // Each host cluster the data touches is referenced once by this
        // entry. It continues in the last cluster made for deflated data
        // while that is still the file's last (sharing it: one more
        // reference); clusters it runs on into are new (allocate counts them).
        // (Refcount blocks are made first: one landing after the cursor's
        // cluster ends the run, so the choice is made after.)
        try reserveContiguous(through: nextCluster + len + cs)
        let continuing = compressedCursor != 0 && (compressedCursor / cs + 1) * cs == nextCluster
        let begin = continuing ? compressedCursor : nextCluster
        let end = begin + len
        if continuing {
            try addRef(begin / cs * cs, 1)
        }
        while nextCluster < end { _ = try allocate() }
        try file.Write(deflated, at: int64(begin))
        let sectorBits = uint64(Header.ClusterBits) - 8
        let offsetBits = 62 - sectorBits
        let extraSectors = ((end - 1) >> 9) - (begin >> 9)
        try setL2(offset, compressedFlag | (extraSectors << offsetBits) | begin)
        compressedCursor = (end + 511) / 512 * 512
        if compressedCursor % cs == 0 { compressedCursor = 0 }
    }
}
