package boot

import (
    "encoding/binary"
    "vm/device"
)

// The subset of ELF64 the loaders need: program headers (PT_LOAD) and
// notes (PT_NOTE). The Desktop's elf/ is Go toolchain code, not a Vertex
// package; if a second Vertex user of ELF appears, this moves out.

let elfMagic: uint32 = 0x464c_457f   // "\x7fELF"
let ptLoad: uint32 = 1
let ptNote: uint32 = 4

public struct ProgramHeader {
    public let Type: uint32
    public let Offset: uint64
    public let PhysicalAddress: uint64
    public let FileSize: uint64
    public let MemorySize: uint64
}

public struct Elf {
    public let Entry: uint64
    public let Programs: [ProgramHeader]
    let bytes: [uint8]

    /// The notes in PT_NOTE segments: (type, name, descriptor).
    public func Notes() -> [(type: uint32, name: string, desc: [uint8])] {
        var out: [(type: uint32, name: string, desc: [uint8])] = []
        for ph in Programs where ph.Type == ptNote {
            var at = int(ph.Offset)
            let end = at + int(ph.FileSize)
            while at + 12 <= end {
                let nameSize = int(binary.LittleEndian.Uint32(bytes, from: at))
                let descSize = int(binary.LittleEndian.Uint32(bytes, from: at + 4))
                let type = binary.LittleEndian.Uint32(bytes, from: at + 8)
                let nameAt = at + 12
                let descAt = nameAt + (nameSize + 3) & ~3
                if descAt + descSize > bytes.count { break }
                let name = string(decoding: Array(bytes[nameAt..<nameAt + max(0, nameSize - 1)]), as: UTF8.self)
                out.append((type: type, name: name, desc: Array(bytes[descAt..<descAt + descSize])))
                at = descAt + (descSize + 3) & ~3
            }
        }
        return out
    }

    /// Each PT_LOAD segment as bytes for its physical address, with the
    /// part past FileSize (bss) zero-filled.
    public func Loads() -> [Load] {
        var out: [Load] = []
        for ph in Programs where ph.Type == ptLoad {
            var seg = Array(bytes[int(ph.Offset)..<int(ph.Offset + ph.FileSize)])
            if ph.MemorySize > ph.FileSize {
                seg.append(contentsOf: [uint8](repeating: 0, count: int(ph.MemorySize - ph.FileSize)))
            }
            out.append(Load(Address: device.GuestAddress(ph.PhysicalAddress), Bytes: seg))
        }
        return out
    }
}

public func ParseElf(_ b: [uint8]) throws -> Elf {
    if b.count < 64 || binary.LittleEndian.Uint32(b, from: 0) != elfMagic || b[4] != 2 || b[5] != 1 {
        throw BootError.badImage("not a little-endian ELF64 file")
    }
    let phoff = int(binary.LittleEndian.Uint64(b, from: 32))
    let phentsize = int(binary.LittleEndian.Uint16(b, from: 54))
    let phnum = int(binary.LittleEndian.Uint16(b, from: 56))
    if phoff + phentsize * phnum > b.count {
        throw BootError.badImage("program headers past the end of the file")
    }
    var phs: [ProgramHeader] = []
    for i in 0..<phnum {
        let at = phoff + i * phentsize
        let ph = ProgramHeader(
            Type: binary.LittleEndian.Uint32(b, from: at),
            Offset: binary.LittleEndian.Uint64(b, from: at + 8),
            PhysicalAddress: binary.LittleEndian.Uint64(b, from: at + 24),
            FileSize: binary.LittleEndian.Uint64(b, from: at + 32),
            MemorySize: binary.LittleEndian.Uint64(b, from: at + 40)
        )
        if ph.Offset + ph.FileSize > uint64(b.count) {
            throw BootError.badImage("segment \(i) past the end of the file")
        }
        phs.append(ph)
    }
    return Elf(Entry: binary.LittleEndian.Uint64(b, from: 24), Programs: phs, bytes: b)
}
