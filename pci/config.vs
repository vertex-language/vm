package pci

/// Class codes (base class, subclass, programming interface) for the
/// functions the vm packages make.
public struct ClassCode {
    public let Base: uint8
    public let Sub: uint8
    public let Interface: uint8

    public init(_ base: uint8, _ sub: uint8, _ interface: uint8) {
        Base = base
        Sub = sub
        Interface = interface
    }

    public static let hostBridge = ClassCode(0x06, 0x00, 0x00)
    public static let nvme = ClassCode(0x01, 0x08, 0x02)
    public static let xhci = ClassCode(0x0c, 0x03, 0x30)
    public static let ethernet = ClassCode(0x02, 0x00, 0x00)
    public static let scsi = ClassCode(0x01, 0x00, 0x00)
    public static let other = ClassCode(0xff, 0x00, 0x00)

    /// The class a VirtIO device reports, by VirtIO device ID.
    public static func forVirtio(_ id: uint32) -> ClassCode {
        switch id {
        case 1: return ClassCode(0x02, 0x00, 0x00)    // net
        case 2: return ClassCode(0x01, 0x80, 0x00)    // block: other mass storage
        case 3: return ClassCode(0x07, 0x80, 0x00)    // console: other communication
        case 16: return ClassCode(0x03, 0x80, 0x00)   // gpu: other display
        case 18: return ClassCode(0x09, 0x80, 0x00)   // input
        default: return ClassCode(0xff, 0x00, 0x00)
        }
    }
}

/// A type-0 configuration header (4 KiB of extended config space) and its
/// capability list. Functions fill it in; Root answers config cycles from
/// it and handles the parts the spec defines (command, BARs, MSI-X enable).
public final class ConfigSpace {
    public var Bytes: [uint8] = [uint8](repeating: 0, count: 4096)
    /// Where the next capability goes. Capabilities start after the header.
    var nextCap: int = 0x40
    var lastCap: int = 0

    public init(vendor: uint16, device: uint16, classCode: ClassCode, revision: uint8,
                subsystemVendor: uint16 = 0x1af4, subsystem: uint16 = 0x1100) {
        put16(0x00, vendor)
        put16(0x02, device)
        Bytes[0x08] = revision
        Bytes[0x09] = classCode.Interface
        Bytes[0x0a] = classCode.Sub
        Bytes[0x0b] = classCode.Base
        put16(0x2c, subsystemVendor)
        put16(0x2e, subsystem)
        Bytes[0x3d] = 1          // interrupt pin INTA
        put16(0x06, 0x0010)      // status: capabilities list
    }

    /// Appends a capability with the given ID and body; returns its offset.
    @discardableResult
    public func AddCapability(id: uint8, body: [uint8]) -> int {
        let at = nextCap
        Bytes[at] = id
        Bytes[at + 1] = 0
        for i in 0..<body.count {
            Bytes[at + 2 + i] = body[i]
        }
        if lastCap == 0 {
            Bytes[0x34] = uint8(at)
        } else {
            Bytes[lastCap + 1] = uint8(at)
        }
        lastCap = at
        nextCap = (at + 2 + body.count + 3) & ~3
        return at
    }

    public var Command: uint16 { get16(0x04) }
    public var MemoryEnabled: bool { Command & 0x2 != 0 }
    public var BusMasterEnabled: bool { Command & 0x4 != 0 }

    public func Read(offset: int, size: uint8) -> uint32 {
        var v: uint32 = 0
        for i in 0..<int(size) where offset + i < Bytes.count {
            v |= uint32(Bytes[offset + i]) << (8 * uint32(i))
        }
        return v
    }

    func put16(_ at: int, _ v: uint16) {
        Bytes[at] = uint8(v & 0xff)
        Bytes[at + 1] = uint8(v >> 8)
    }

    func get16(_ at: int) -> uint16 {
        uint16(Bytes[at]) | (uint16(Bytes[at + 1]) << 8)
    }
}
