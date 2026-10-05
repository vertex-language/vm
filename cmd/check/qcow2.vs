// QCOW2 writing: a new image written every way a writer can (part of a
// cluster, across clusters, in place, deflated, over a deflated cluster,
// on top of a backing image), read back against the bytes meant, and
// checked by qemu-img where the machine has it (a test-only oracle).
package main

import (
    "fs"
    "os/process"
    "vm/disk"
    "vm/disk/qcow2"
)

/// A cluster-sized run of `v`, with its offset stamped in so clusters differ.
func pattern(_ v: uint8, _ n: int, _ at: uint64) -> [uint8] {
    var b = [uint8](repeating: v, count: n)
    for i in 0..<min(8, n) { b[i] = uint8(truncatingIfNeeded: at >> uint64(8 * i)) }
    return b
}

func qemuImg() -> string? {
    for p in ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img", "/usr/bin/qemu-img"] where fs.Exists(fs.Path(p)) { return p }
    return nil
}

func checkQcow2Write() async {
    let dir = "/tmp/vm-check-qcow2"
    try? fs.RemoveAll(fs.Path(dir))
    try? fs.CreateDir(fs.Path(dir))
    let path = fs.Path(dir + "/a.qcow2")
    let size: uint64 = 3 << 30           // 3 GiB: past one refcount block's 2 GiB
    let cs: uint64 = 65536
    var want: [uint64: [uint8]] = [:]    // cluster start → its expected bytes
    func expect(_ at: uint64, _ bytes: [uint8]) {
        var done = 0
        while done < bytes.count {
            let a = at + uint64(done)
            let start = a - a % cs
            var c = want[start] ?? [uint8](repeating: 0, count: int(cs))
            let n = min(int(cs - a % cs), bytes.count - done)
            for i in 0..<n { c[int(a % cs) + i] = bytes[done + i] }
            want[start] = c
            done += n
        }
    }
    do {
        let img = try qcow2.Create(path, size: size)
        check(img.Size == size && img.Header.Version == 3, "qcow2: Create makes a version 3 image of the size asked")
        // Part of a cluster, then across a cluster boundary, then in place.
        let a = pattern(0x11, 100, 5)
        try await img.WriteAt(5, a)
        expect(5, a)
        let b = pattern(0x22, int(cs) + 300, cs - 100)
        try await img.WriteAt(cs - 100, b)
        expect(cs - 100, b)
        let c = pattern(0x33, 50, 20)
        try await img.WriteAt(20, c)
        expect(20, c)
        // Deflated clusters, packed together; then one written over.
        for k in 0..<6 {
            let at = uint64(10 + k) * cs
            let bytes = k == 5 ? pattern(uint8(0x40 + k), int(cs), at) : [uint8](repeating: uint8(0x40 + k), count: int(cs))
            try img.WriteCompressed(at, bytes)
            expect(at, bytes)
        }
        let over = pattern(0x55, 1000, 12 * cs + 77)
        try await img.WriteAt(12 * cs + 77, over)
        expect(12 * cs + 77, over)
        // Far out: past the first refcount block's reach, and the last byte.
        let far = pattern(0x66, 4096, (5 << 29) + 12345)
        try await img.WriteAt((5 << 29) + 12345, far)
        expect((5 << 29) + 12345, far)
        let last = [uint8(0x77)]
        try await img.WriteAt(size - 1, last)
        expect(size - 1, last)
        try await img.Flush()
        img.Close()

        let f = try fs.Open(path)
        let back = try qcow2.Open(f, readOnly: true)
        var same = true
        for (start, bytes) in want {
            var got = [uint8](repeating: 0, count: int(cs))
            try await back.ReadAt(start, into: &got)
            if got != bytes { same = false }
        }
        var hole = [uint8](repeating: 1, count: 4096)
        try await back.ReadAt(1 << 30, into: &hole)
        check(same && hole.allSatisfy({ $0 == 0 }), "qcow2: every byte written reads back, unwritten clusters read as zeros (\(want.count) clusters)")
        back.Close()

        // A copy-on-write overlay over a raw base.
        let basePath = fs.Path(dir + "/base.raw")
        let baseFile = try fs.Create(basePath)
        try baseFile.SetLength(int64(4 * cs))
        try baseFile.Write([uint8](repeating: 0xAB, count: int(4 * cs)), at: 0)
        try baseFile.Close()
        let overlayPath = fs.Path(dir + "/overlay.qcow2")
        let overlay = try qcow2.Create(overlayPath, size: 4 * cs, backing: "base.raw",
                                       openBacking: { name in try disk.OpenRaw(fs.Path(dir + "/" + name), readOnly: true) })
        try await overlay.WriteAt(cs + 10, [1, 2, 3])
        var cow = [uint8](repeating: 0, count: int(cs))
        try await overlay.ReadAt(cs, into: &cow)
        var untouched = [uint8](repeating: 0, count: 16)
        try await overlay.ReadAt(2 * cs, into: &untouched)
        check(cow[9] == 0xAB && cow[10] == 1 && cow[12] == 3 && cow[13] == 0xAB && untouched.allSatisfy({ $0 == 0xAB }),
              "qcow2: a partial write over a backing image copies the rest of the cluster up")
        overlay.Close()
        if let q = qemuImg() {
            let out = try? await process.Command(q, ["check", overlayPath.description]).Output()
            check(out?.Status.Success == true, "qcow2: qemu-img check reads the overlay and its backing name")
        }
    } catch {
        check(false, "qcow2 writing threw \(error)")
        return
    }
    if let q = qemuImg() {
        let out = try? await process.Command(q, ["check", path.description]).Output()
        check(out?.Status.Success == true, "qcow2: qemu-img check finds no errors or leaks \(out.map { $0.StdoutText + $0.StderrText } ?? "")")
    }
}
