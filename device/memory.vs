// Package device is everything a device model sees of a machine: guest
// memory to DMA into, a bus slot to be reached through, and interrupts to
// raise. Device packages (virtio, nvme, usb, chipset) import this and never
// vm or vm/hypervisor, so each one runs in cmd/check against a plain buffer.
package device

/// A guest-physical address.
public struct GuestAddress: Equatable, Comparable, Hashable {
    public let Value: uint64

    public init(_ value: uint64) {
        Value = value
    }

    public func Adding(_ n: uint64) -> GuestAddress {
        GuestAddress(Value &+ n)
    }

    public static func < (a: GuestAddress, b: GuestAddress) -> bool {
        a.Value < b.Value
    }
}

/// One contiguous run of guest RAM and the host memory behind it.
public struct Region {
    public let Guest: GuestAddress
    public let Count: uint64
    public let Host: UnsafeMutableRawPointer

    public init(guest: GuestAddress, count: uint64, host: UnsafeMutableRawPointer) {
        Guest = guest
        Count = count
        Host = host
    }

    func contains(_ at: GuestAddress, _ n: uint64) -> bool {
        at.Value >= Guest.Value && n <= Count && at.Value - Guest.Value <= Count - n
    }
}

/// MemoryError is a guest address a device was handed that isn't RAM.
/// Guests hand devices addresses, so this is a guest bug for the device
/// to report (a VirtIO NEEDS_RESET, an NVMe status), never a host crash.
public enum MemoryError: Error {
    case outOfRange(address: uint64, count: uint64)
}

/// The machine's RAM, by guest-physical address. Every access is bounds
/// checked against the regions.
///
/// Ring indices shared with a running guest (VirtIO avail/used idx, NVMe
/// doorbells shadowed in memory) use the atomic loads and stores; plain
/// Read/Write is for buffers the protocol says the device owns.
public final class GuestMemory {
    public let Regions: [Region]

    public init(_ regions: [Region]) {
        Regions = regions.sorted { $0.Guest < $1.Guest }
    }

    /// A host pointer to `count` bytes at `at`, when they sit in one region.
    public func Pointer(_ at: GuestAddress, count: uint64) throws -> UnsafeMutableRawPointer {
        for r in Regions {
            if r.contains(at, count) {
                return r.Host + int(at.Value - r.Guest.Value)
            }
        }
        throw MemoryError.outOfRange(address: at.Value, count: count)
    }

    public func Read(_ at: GuestAddress, into buffer: inout [uint8]) throws {
        if buffer.isEmpty { return }
        let p = try Pointer(at, count: uint64(buffer.count))
        buffer.withUnsafeMutableBytes {
            guard let base = $0.baseAddress else { return }
            base.copyMemory(from: UnsafeRawPointer(p), byteCount: $0.count)
        }
    }

    public func Read(_ at: GuestAddress, count: int) throws -> [uint8] {
        if count <= 0 { return [] }
        var b = [uint8](repeating: 0, count: count)
        try Read(at, into: &b)
        return b
    }

    public func Write(_ at: GuestAddress, _ bytes: borrowing [uint8]) throws {
        if bytes.isEmpty { return }
        let p = try Pointer(at, count: uint64(bytes.count))
        bytes.withUnsafeBytes {
            guard let base = $0.baseAddress else { return }
            p.copyMemory(from: UnsafeRawPointer(base), byteCount: $0.count)
        }
    }

    public func Load16(_ at: GuestAddress) throws -> uint16 {
        try Pointer(at, count: 2).assumingMemoryBound(to: uint16.self).pointee
    }

    public func Store16(_ at: GuestAddress, _ v: uint16) throws {
        let p = try Pointer(at, count: 2).assumingMemoryBound(to: uint16.self)
        p.pointee = v
    }

    public func Load32(_ at: GuestAddress) throws -> uint32 {
        try Pointer(at, count: 4).assumingMemoryBound(to: uint32.self).pointee
    }

    public func Store32(_ at: GuestAddress, _ v: uint32) throws {
        let p = try Pointer(at, count: 4).assumingMemoryBound(to: uint32.self)
        p.pointee = v
    }

    public func Load64(_ at: GuestAddress) throws -> uint64 {
        try Pointer(at, count: 8).assumingMemoryBound(to: uint64.self).pointee
    }

    public func Store64(_ at: GuestAddress, _ v: uint64) throws {
        let p = try Pointer(at, count: 8).assumingMemoryBound(to: uint64.self)
        p.pointee = v
    }
}
