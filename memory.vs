package vm

import (
    "fs/mmap"
    "vm/device"
    "vm/hypervisor"
)

/// GuestRam manages host-allocated memory mapped into a partition as guest RAM.
public final class GuestRam {
    let mapping: mmap.Mapping
    public let Base: uint64
    public let Size: uint64
    public let Memory: device.GuestMemory

    public init(base: uint64, size: uint64) throws {
        self.Base = base
        self.Size = size
        self.mapping = try mmap.Anonymous(int(size))
        guard let ptr = mapping.RawPointer else {
            throw VmError.memoryAllocationFailed("failed to allocate \(size) bytes for guest RAM")
        }
        let region = device.Region(guest: device.GuestAddress(base), count: size, host: ptr)
        self.Memory = device.GuestMemory([region])
    }

    public func Map(into partition: hypervisor.Partition) throws {
        guard let ptr = mapping.RawPointer else { return }
        try partition.Map(guest: Base, host: ptr, count: Size, access: .all)
    }

    public var HostPointer: UnsafeMutableRawPointer? {
        mapping.RawPointer
    }

    public var Range: device.Range {
        device.Range(base: Base, count: Size)
    }
}
