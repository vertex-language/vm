package acpi

import "encoding/binary"

/// A tiny AML (ACPI Machine Language) writer: enough to describe devices
/// in a DSDT: names, integers, strings, buffers, packages, devices,
/// methods and resource templates. It builds bytecode directly; there's no
/// ASL compiler involved.
public struct Aml {
    public var Bytes: [uint8] = []

    public init() {}

    // Opcodes.
    static let zeroOp: uint8 = 0x00
    static let oneOp: uint8 = 0x01
    static let nameOp: uint8 = 0x08
    static let bytePrefix: uint8 = 0x0a
    static let wordPrefix: uint8 = 0x0b
    static let dwordPrefix: uint8 = 0x0c
    static let stringPrefix: uint8 = 0x0d
    static let qwordPrefix: uint8 = 0x0e
    static let scopeOp: uint8 = 0x10
    static let bufferOp: uint8 = 0x11
    static let packageOp: uint8 = 0x12
    static let methodOp: uint8 = 0x14
    static let returnOp: uint8 = 0xa4
    static let extPrefix: uint8 = 0x5b
    static let deviceOp: uint8 = 0x82

    /// Name(NAME, value)
    public mutating func Name(_ name: string, _ value: Aml) {
        Bytes.append(Aml.nameOp)
        Bytes.append(contentsOf: nameSeg(name))
        Bytes.append(contentsOf: value.Bytes)
    }

    public static func Integer(_ v: uint64) -> Aml {
        var a = Aml()
        if v == 0 {
            a.Bytes = [zeroOp]
        } else if v == 1 {
            a.Bytes = [oneOp]
        } else if v <= 0xff {
            a.Bytes = [bytePrefix, uint8(v)]
        } else if v <= 0xffff {
            a.Bytes = [wordPrefix]
            binary.LittleEndian.AppendUint16(&a.Bytes, uint16(v))
        } else if v <= 0xffff_ffff {
            a.Bytes = [dwordPrefix]
            binary.LittleEndian.AppendUint32(&a.Bytes, uint32(v))
        } else {
            a.Bytes = [qwordPrefix]
            binary.LittleEndian.AppendUint64(&a.Bytes, v)
        }
        return a
    }

    public static func String(_ s: string) -> Aml {
        var a = Aml()
        a.Bytes = [stringPrefix] + Array(s.utf8) + [0]
        return a
    }

    /// An EISA ID such as "PNP0501", compressed to 32 bits.
    public static func EisaId(_ id: string) -> Aml {
        let c = Array(id.utf8)
        let v: uint32 = ((uint32(c[0]) - 0x40) << 26) | ((uint32(c[1]) - 0x40) << 21) | ((uint32(c[2]) - 0x40) << 16)
            | (hex(c[3]) << 12) | (hex(c[4]) << 8) | (hex(c[5]) << 4) | hex(c[6])
        let swapped = ((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v >> 8) & 0xff00) | (v >> 24)
        return Integer(uint64(swapped))
    }

    public static func Buffer(_ bytes: [uint8]) -> Aml {
        var body = Integer(uint64(bytes.count)).Bytes
        body.append(contentsOf: bytes)
        var a = Aml()
        a.Bytes = [bufferOp] + pkgLength(body.count) + body
        return a
    }

    public static func Package(_ items: [Aml]) -> Aml {
        var body: [uint8] = [uint8(items.count)]
        for i in items { body.append(contentsOf: i.Bytes) }
        var a = Aml()
        a.Bytes = [packageOp] + pkgLength(body.count) + body
        return a
    }

    /// Device(NAME) { body }
    public mutating func Device(_ name: string, _ body: Aml) {
        let inner = nameSeg(name) + body.Bytes
        Bytes.append(contentsOf: [Aml.extPrefix, Aml.deviceOp])
        Bytes.append(contentsOf: Aml.pkgLength(inner.count) + inner)
    }

    /// Scope(PATH) { body }, e.g. "\\_SB_".
    public mutating func Scope(_ path: string, _ body: Aml) {
        let inner = namePath(path) + body.Bytes
        Bytes.append(Aml.scopeOp)
        Bytes.append(contentsOf: Aml.pkgLength(inner.count) + inner)
    }

    /// Method(NAME, 0) { Return(value) }
    public mutating func ReturnMethod(_ name: string, _ value: Aml) {
        let inner = nameSeg(name) + [0] + [Aml.returnOp] + value.Bytes
        Bytes.append(Aml.methodOp)
        Bytes.append(contentsOf: Aml.pkgLength(inner.count) + inner)
    }

    /// Method(NAME, 1) { Notify(target, value) }
    public mutating func NotifyMethod(_ name: string, target: string, value: uint8) {
        let inner = nameSeg(name) + [1] + [0x86] + nameSeg(target) + [Aml.bytePrefix, value]
        Bytes.append(Aml.methodOp)
        Bytes.append(contentsOf: Aml.pkgLength(inner.count) + inner)
    }

    public mutating func Append(_ other: Aml) {
        Bytes.append(contentsOf: other.Bytes)
    }

    static func pkgLength(_ n: int) -> [uint8] {
        // The length counts its own bytes too.
        if n + 1 < 0x40 {
            return [uint8(n + 1)]
        }
        if n + 2 < 0x1000 {
            let l = n + 2
            return [uint8(0x40 | (l & 0xf)), uint8(l >> 4)]
        }
        if n + 3 < 0x10_0000 {
            let l = n + 3
            return [uint8(0x80 | (l & 0xf)), uint8((l >> 4) & 0xff), uint8(l >> 12)]
        }
        let l = n + 4
        return [uint8(0xc0 | (l & 0xf)), uint8((l >> 4) & 0xff), uint8((l >> 12) & 0xff), uint8(l >> 20)]
    }

    static func hex(_ c: uint8) -> uint32 {
        c >= 0x41 ? uint32(c - 0x41 + 10) : uint32(c - 0x30)
    }
}

/// A 4-character name segment, padded with '_'.
func nameSeg(_ s: string) -> [uint8] {
    var b = Array(s.utf8)
    while b.count < 4 { b.append(0x5f) }
    return Array(b[0..<4])
}

/// "\\_SB_" or "_SB_.PCI0": a root prefix and dotted segments.
func namePath(_ s: string) -> [uint8] {
    var out: [uint8] = []
    var rest = Array(s.utf8)
    if rest.first == 0x5c {
        out.append(0x5c)
        rest.removeFirst()
    }
    let segs = rest.split(separator: 0x2e)
    if segs.count == 2 {
        out.append(0x2e)   // DualNamePrefix
    } else if segs.count > 2 {
        out.append(0x2f)   // MultiNamePrefix
        out.append(uint8(segs.count))
    }
    for s in segs {
        out.append(contentsOf: nameSeg(string(decoding: Array(s), as: UTF8.self)))
    }
    return out
}

/// Resource templates for _CRS: the descriptors the DSDT's devices need.
public struct Resources {
    public var Bytes: [uint8] = []

    public init() {}

    /// A 32-bit fixed memory range.
    public mutating func Memory32(base: uint32, count: uint32) {
        Bytes.append(contentsOf: [0x86, 9, 0, 1])   // Memory32Fixed, read/write
        binary.LittleEndian.AppendUint32(&Bytes, base)
        binary.LittleEndian.AppendUint32(&Bytes, count)
    }

    /// An extended interrupt: a GIC SPI or IOAPIC GSI, level, active high.
    public mutating func Interrupt(_ gsi: uint32, edge: bool = false) {
        Bytes.append(contentsOf: [0x89, 6, 0, edge ? 0x03 : 0x01, 1])
        binary.LittleEndian.AppendUint32(&Bytes, gsi)
    }

    /// A fixed I/O port range.
    public mutating func Io(base: uint16, count: uint8) {
        Bytes.append(contentsOf: [0x47, 1])
        binary.LittleEndian.AppendUint16(&Bytes, base)
        binary.LittleEndian.AppendUint16(&Bytes, base)
        Bytes.append(1)
        Bytes.append(count)
    }

    /// WordBusNumber descriptor (0x88, 13 bytes payload)
    public mutating func WordBusNumber(minBus: uint16, maxBus: uint16) {
        Bytes.append(contentsOf: [0x88, 13, 0, 2, 0x0c, 0])
        binary.LittleEndian.AppendUint16(&Bytes, 0) // granularity
        binary.LittleEndian.AppendUint16(&Bytes, minBus)
        binary.LittleEndian.AppendUint16(&Bytes, maxBus)
        binary.LittleEndian.AppendUint16(&Bytes, 0) // translation
        binary.LittleEndian.AppendUint16(&Bytes, maxBus - minBus + 1)
    }

    /// DWordMemory descriptor (0x87, 23 bytes payload)
    public mutating func DWordMemory(base: uint32, size: uint32) {
        Bytes.append(contentsOf: [0x87, 23, 0, 0, 0x0c, 1])   // memory, fixed, read-write
        binary.LittleEndian.AppendUint32(&Bytes, 0) // granularity
        binary.LittleEndian.AppendUint32(&Bytes, base)
        binary.LittleEndian.AppendUint32(&Bytes, base + size - 1)
        binary.LittleEndian.AppendUint32(&Bytes, 0) // translation
        binary.LittleEndian.AppendUint32(&Bytes, size)
    }

    /// QWordMemory descriptor (0x8a, 43 bytes payload)
    public mutating func QWordMemory(base: uint64, size: uint64) {
        Bytes.append(contentsOf: [0x8a, 43, 0, 0, 0x0c, 1])   // memory, fixed, read-write
        binary.LittleEndian.AppendUint64(&Bytes, 0) // granularity
        binary.LittleEndian.AppendUint64(&Bytes, base)
        binary.LittleEndian.AppendUint64(&Bytes, base + size - 1)
        binary.LittleEndian.AppendUint64(&Bytes, 0) // translation
        binary.LittleEndian.AppendUint64(&Bytes, size)
    }

    /// DWordIo descriptor (0x87, 23 bytes payload)
    public mutating func DWordIo(min: uint32, max: uint32, translation: uint32, length: uint32) {
        // I/O, fixed, entire range, type translation: memory on the host side.
        Bytes.append(contentsOf: [0x87, 23, 0, 1, 0x0c, 0x13])
        binary.LittleEndian.AppendUint32(&Bytes, 0) // granularity
        binary.LittleEndian.AppendUint32(&Bytes, min)
        binary.LittleEndian.AppendUint32(&Bytes, max)
        binary.LittleEndian.AppendUint32(&Bytes, translation)
        binary.LittleEndian.AppendUint32(&Bytes, length)
    }

    /// The template as a Buffer, with its end tag.
    public func Template() -> Aml {
        Aml.Buffer(Bytes + [0x79, 0])
    }
}

/// The Differentiated System Description Table: the AML for the whole
/// machine, under \_SB.
public func Dsdt(_ body: Aml) -> [uint8] {
    var t = Table(signature: "DSDT", revision: 2)
    t.Append(body.Bytes)
    return t.Finish()
}
