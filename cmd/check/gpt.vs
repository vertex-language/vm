// GptDisk: a GPT disk put together from other images, read back through
// disk.Partitions, with its tables' checksums, and reads and writes that
// land in the partitions they address.
package main

import (
    "crypto/crc32"
    "encoding/binary"
    "vm/disk"
)

func checkGptDisk() async {
    let a: any disk.Image = disk.MemoryImage(bytes: [uint8](repeating: 0xA1, count: 3 << 20))
    let b: any disk.Image = disk.MemoryImage(bytes: [uint8](repeating: 0xB2, count: 4096))
    let g = disk.GptDisk(names: ["vendor", "oem"], images: [a, b])
    guard let parts = try? await disk.Partitions(g) else {
        check(false, "GptDisk: partitions read back")
        return
    }
    check(parts.count == 2 && parts[0].Name == "vendor" && parts[1].Name == "oem", "GptDisk: both partitions, named, in order")
    if parts.count != 2 { return }
    check(parts[0].Offset == 1 << 20 && parts[0].Size == 3 << 20, "GptDisk: the first starts at 1 MiB, its image's size")
    check(parts[1].Offset == 4 << 20 && parts[1].Size == 4096, "GptDisk: the next starts on the next MiB")

    var hdr = [uint8](repeating: 0, count: 512)
    var backup = [uint8](repeating: 0, count: 512)
    var entries = [uint8](repeating: 0, count: 128 * 128)
    try? await g.ReadAt(512, into: &hdr)
    try? await g.ReadAt(g.Size - 512, into: &backup)
    try? await g.ReadAt(1024, into: &entries)
    func headerCrcOk(_ h: [uint8]) -> bool {
        var z = Array(h[0..<92])
        for i in 16..<20 { z[i] = 0 }
        return crc32.ChecksumIEEE(z) == binary.LittleEndian.Uint32(h, from: 16)
    }
    check(headerCrcOk(hdr) && headerCrcOk(backup), "GptDisk: both headers' CRCs hold")
    check(crc32.ChecksumIEEE(entries) == binary.LittleEndian.Uint32(hdr, from: 88), "GptDisk: the table's CRC holds")
    check(binary.LittleEndian.Uint64(backup, from: 24) == g.Size / 512 - 1 && binary.LittleEndian.Uint64(hdr, from: 32) == g.Size / 512 - 1,
          "GptDisk: the backup header is the last sector, and the primary says so")

    // Reads across the end of one partition into the next, and from the
    // end of the last into the gap before the backup table.
    var across = [uint8](repeating: 0xFF, count: 8)
    try? await g.ReadAt(parts[0].Offset + parts[0].Size - 4, into: &across)
    check(across == [0xA1, 0xA1, 0xA1, 0xA1, 0xB2, 0xB2, 0xB2, 0xB2], "GptDisk: a read runs from one partition into the next")
    var gap = [uint8](repeating: 0xFF, count: 8)
    try? await g.ReadAt(parts[1].Offset + parts[1].Size - 4, into: &gap)
    check(gap == [0xB2, 0xB2, 0xB2, 0xB2, 0, 0, 0, 0], "GptDisk: and from the last into zeroes")
    var inB = [uint8](repeating: 0, count: 4)
    try? await g.ReadAt(parts[1].Offset, into: &inB)
    check(inB == [0xB2, 0xB2, 0xB2, 0xB2], "GptDisk: the second partition reads its image")
    try? await g.WriteAt(parts[1].Offset + 8, [1, 2, 3])
    var back = [uint8](repeating: 0, count: 3)
    try? await b.ReadAt(8, into: &back)
    check(back == [1, 2, 3], "GptDisk: a write lands in the partition's image")
}
