// Package acpi builds the ACPI tables a guest's firmware or kernel reads
// to find its hardware, for arm64 and amd64 alike: Windows needs them on
// both, and so does Linux under UEFI.
//
// Tables are hardware-reduced (no PM1 blocks, no SCI, no legacy timers);
// the power button and hotplug go through a Generic Event Device in the
// DSDT. Every builder returns bytes with the checksum already set.
package acpi

import "encoding/binary"

typealias LE = binary.LittleEndian

/// The OEM fields every table carries.
public let OemId: [uint8] = Array("VERTEX".utf8)
public let OemTableId: [uint8] = Array("VERTEXVM".utf8)
let creatorId: [uint8] = Array("VTXC".utf8)

/// A table being built: the 36-byte standard header, then the body.
public struct Table {
    public var Bytes: [uint8]

    public init(signature: string, revision: uint8) {
        Bytes = [uint8](repeating: 0, count: 36)
        let sig = Array(signature.utf8)
        for i in 0..<4 { Bytes[i] = sig[i] }
        Bytes[8] = revision
        for i in 0..<6 { Bytes[10 + i] = OemId[i] }
        for i in 0..<8 { Bytes[16 + i] = OemTableId[i] }
        LE.PutUint32(&Bytes, 1, at: 24)              // OEM revision
        for i in 0..<4 { Bytes[28 + i] = creatorId[i] }
        LE.PutUint32(&Bytes, 1, at: 32)              // creator revision
    }

    public mutating func U8(_ v: uint8) { Bytes.append(v) }
    public mutating func U16(_ v: uint16) { LE.AppendUint16(&Bytes, v) }
    public mutating func U32(_ v: uint32) { LE.AppendUint32(&Bytes, v) }
    public mutating func U64(_ v: uint64) { LE.AppendUint64(&Bytes, v) }
    public mutating func Append(_ b: [uint8]) { Bytes.append(contentsOf: b) }
    public mutating func Zeroes(_ n: int) { Bytes.append(contentsOf: [uint8](repeating: 0, count: n)) }

    /// A Generic Address Structure (12 bytes).
    public mutating func Gas(space: uint8, bitWidth: uint8, bitOffset: uint8 = 0, accessSize: uint8, address: uint64) {
        U8(space); U8(bitWidth); U8(bitOffset); U8(accessSize); U64(address)
    }

    /// Sets the length and checksum; the table is done.
    public func Finish() -> [uint8] {
        var b = Bytes
        LE.PutUint32(&b, uint32(b.count), at: 4)
        b[9] = 0
        b[9] = Checksum(b)
        return b
    }
}

/// The byte that makes a table's bytes sum to zero.
public func Checksum(_ b: [uint8]) -> uint8 {
    var sum: uint8 = 0
    for x in b { sum &+= x }
    return 0 &- sum
}

public enum AddressSpace {
    public static let memory: uint8 = 0
    public static let io: uint8 = 1
}
