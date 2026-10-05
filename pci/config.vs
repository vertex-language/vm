package pci

import (
    "sync"
    "vm/device"
)

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
/// it and handles the parts the spec defines (command, BARs).
///
/// Only bytes marked writable take guest writes: the command register,
/// cache line size, latency timer, interrupt line, and whatever a function
/// marks with `SetWritable`. Everything else is read-only, as on hardware.
public final class ConfigSpace {
    public var Bytes: [uint8] = [uint8](repeating: 0, count: 4096)
    /// Per byte: which bits a guest write may change.
    var writable: [uint8] = [uint8](repeating: 0, count: 4096)
    /// Where the next capability goes. Capabilities start after the header.
    var nextCap: int = 0x40
    var lastCap: int = 0
    let lock = sync.Mutex()
    /// The INTx line Root wired this function to, and the level the
    /// function last asked for.
    var intx: (any device.Irq)? = nil
    var intxWanted = false
    /// The MSI-X capability's offset and table, if the function has one.
    var msixCap = 0
    var msix: MsixTable? = nil

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
        // Command: I/O, memory, bus master, parity, SERR#, interrupt disable.
        SetWritable(0x04, 2, mask: 0x0547)
        SetWritable(0x0c, 1)     // cache line size
        SetWritable(0x0d, 1)     // latency timer
        SetWritable(0x3c, 1)     // interrupt line
    }

    /// Lets guests write `count` bytes at `at`, under `mask` (little-endian).
    public func SetWritable(_ at: int, _ count: int, mask: uint64 = ~0) {
        for i in 0..<count {
            writable[at + i] = uint8((mask >> (8 * uint64(i))) & 0xff)
        }
    }

    /// Keeps the bytes below `upTo` for registers of the function's own
    /// (xHCI's SBRN and FLADJ at 0x60): capabilities start after them.
    public func ReserveCapabilities(upTo: int) {
        nextCap = max(nextCap, (upTo + 3) & ~3)
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
            Bytes[0x06] |= 0x10  // status: capabilities list present
        } else {
            Bytes[lastCap + 1] = uint8(at)
        }
        lastCap = at
        nextCap = (at + 2 + body.count + 3) & ~3
        return at
    }

    /// A PCI Express capability for a root-complex integrated endpoint:
    /// what PCIe-only drivers (stornvme, usbxhci) look for.
    @discardableResult
    public func AddPcieCapability() -> int {
        var body = [uint8](repeating: 0, count: 0x3a)
        body[0] = 0x92           // capability version 2, device/port type 9 (RCiEP)
        body[4] = 0x00; body[5] = 0x80   // device capabilities: role-based error reporting
        let at = AddCapability(id: 0x10, body: body)
        SetWritable(at + 0x08, 2, mask: 0x7cff)   // device control
        SetWritable(at + 0x28, 2, mask: 0x07ff)   // device control 2
        return at
    }

    /// An MSI-X capability over `table`, whose table and PBA sit in BAR
    /// `bar` at the given offsets. The guest's enable and function-mask
    /// bits go to the table; INTx is off while MSI-X is on.
    @discardableResult
    public func AddMsixCapability(_ table: MsixTable, bar: uint8, tableOffset: uint32, pbaOffset: uint32) -> int {
        let at = AddCapability(id: 0x11, body: table.Capability(bar: bar, tableOffset: tableOffset, pbaOffset: pbaOffset))
        SetWritable(at + 2, 2, mask: 0xc000)
        msixCap = at
        msix = table
        return at
    }

    /// Whether the guest turned MSI-X on.
    public var MsixEnabled: bool {
        lock.withLock { msixCap != 0 && Bytes[msixCap + 3] & 0x80 != 0 }
    }

    public var Command: uint16 { get16(0x04) }
    public var MemoryEnabled: bool { Command & 0x2 != 0 }
    public var BusMasterEnabled: bool { Command & 0x4 != 0 }
    public var IntxDisabled: bool { Command & 0x400 != 0 }

    public func Read(offset: int, size: uint8) -> uint32 {
        lock.withLock {
            var v: uint32 = 0
            for i in 0..<int(size) where offset + i < Bytes.count {
                v |= uint32(Bytes[offset + i]) << (8 * uint32(i))
            }
            return v
        }
    }

    /// A guest configuration write, through the writable mask.
    public func GuestWrite(offset: int, size: uint8, value: uint64) {
        lock.withLock {
            for i in 0..<int(size) where offset + i < Bytes.count {
                let m = writable[offset + i]
                let b = uint8((value >> (8 * uint64(i))) & 0xff)
                Bytes[offset + i] = (Bytes[offset + i] & ~m) | (b & m)
            }
        }
        if offset <= 0x05 && offset + int(size) > 0x04 {
            applyIntx()          // interrupt disable may have changed
        }
        if msixCap != 0 && offset <= msixCap + 3 && offset + int(size) > msixCap + 2 {
            let control = lock.withLock { Bytes[msixCap + 3] }
            msix?.setControl(enabled: control & 0x80 != 0, masked: control & 0x40 != 0)
            applyIntx()          // INTx is off while MSI-X is on
        }
    }

    public func Put32(_ at: int, _ v: uint32) {
        lock.withLock {
            Bytes[at] = uint8(v & 0xff)
            Bytes[at + 1] = uint8((v >> 8) & 0xff)
            Bytes[at + 2] = uint8((v >> 16) & 0xff)
            Bytes[at + 3] = uint8(v >> 24)
        }
    }

    public func Get32(_ at: int) -> uint32 {
        lock.withLock {
            uint32(Bytes[at]) | (uint32(Bytes[at + 1]) << 8) | (uint32(Bytes[at + 2]) << 16) | (uint32(Bytes[at + 3]) << 24)
        }
    }

    /// Connects the function's INTA to an interrupt controller line.
    public func ConnectIntx(_ irq: any device.Irq, line: uint8) {
        lock.withLock {
            intx = irq
            Bytes[0x3c] = line
        }
        applyIntx()
    }

    /// Asserts or deasserts INTA. Level-triggered: hold it while the
    /// function has an interrupt pending. The command register's interrupt
    /// disable bit masks it, and status bit 3 reports it either way.
    public func SetIntx(_ asserted: bool) {
        lock.withLock { intxWanted = asserted }
        applyIntx()
    }

    /// Drives the line under the lock, so that a device asserting and a
    /// guest setting interrupt disable can't leave it at a stale level.
    func applyIntx() {
        lock.withLock {
            if intxWanted { Bytes[0x06] |= 0x08 } else { Bytes[0x06] &= ~0x08 }
            let msixOn = msixCap != 0 && Bytes[msixCap + 3] & 0x80 != 0
            intx?.Set(intxWanted && !IntxDisabled && !msixOn)
        }
    }

    func put16(_ at: int, _ v: uint16) {
        Bytes[at] = uint8(v & 0xff)
        Bytes[at + 1] = uint8(v >> 8)
    }

    func get16(_ at: int) -> uint16 {
        uint16(Bytes[at]) | (uint16(Bytes[at + 1]) << 8)
    }
}
