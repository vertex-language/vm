package device

/// A device reached through memory-mapped registers.
///
/// Register accesses run on a vCPU thread, synchronously: the guest is
/// stopped until `Read` returns. So they take the device's lock, change
/// state and return. Anything slow (disk, network) is started as a task
/// that finishes later and raises an interrupt.
public protocol Mmio: AnyObject {
    /// `offset` is from the start of the device's range; `size` is 1, 2, 4
    /// or 8.
    func Read(offset: uint64, size: uint8) -> uint64
    func Write(offset: uint64, size: uint8, value: uint64)
}

/// A device reached through x86 I/O ports. amd64 guests only.
public protocol Pio: AnyObject {
    func Read(port: uint16, size: uint8) -> uint32
    func Write(port: uint16, size: uint8, value: uint32)
}

/// A range of addresses (or ports) and what answers there.
public struct Range {
    public let Base: uint64
    public let Count: uint64

    public init(base: uint64, count: uint64) {
        Base = base
        Count = count
    }

    public var End: uint64 { Base + Count }

    func overlaps(_ o: Range) -> bool {
        Base < o.End && o.Base < End
    }
}

/// BusError is a device placed where another already is.
public enum BusError: Error {
    case overlap(Range)
}

public final class MmioMatch {
    public let dev: any Mmio
    public let offset: uint64
    public init(dev: any Mmio, offset: uint64) {
        self.dev = dev
        self.offset = offset
    }
}

public final class PioMatch {
    public let dev: any Pio
    public let offset: uint64
    public init(dev: any Pio, offset: uint64) {
        self.dev = dev
        self.offset = offset
    }
}

public final class MmioBus {
    var ranges: [Range] = []
    var devices: [any Mmio] = []

    public init() {}

    public func Insert(_ device: any Mmio, at range: Range) throws {
        var i = 0
        while i < ranges.count && ranges[i].Base < range.Base {
            i += 1
        }
        if i > 0 && ranges[i - 1].overlaps(range) { throw BusError.overlap(range) }
        if i < ranges.count && ranges[i].overlaps(range) { throw BusError.overlap(range) }
        ranges.insert(range, at: i)
        devices.insert(device, at: i)
    }

    public func Remove(at base: uint64) {
        if let i = ranges.firstIndex(where: { $0.Base == base }) {
            ranges.remove(at: i)
            devices.remove(at: i)
        }
    }

    /// The device covering `address`, and the offset into its range.
    public func Find(_ address: uint64) -> MmioMatch? {
        var lo = 0
        var hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].End <= address {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < ranges.count && ranges[lo].Base <= address {
            return MmioMatch(dev: devices[lo], offset: address - ranges[lo].Base)
        }
        return nil
    }
}

public final class PioBus {
    var ranges: [Range] = []
    var devices: [any Pio] = []

    public init() {}

    public func Insert(_ device: any Pio, at range: Range) throws {
        var i = 0
        while i < ranges.count && ranges[i].Base < range.Base {
            i += 1
        }
        if i > 0 && ranges[i - 1].overlaps(range) { throw BusError.overlap(range) }
        if i < ranges.count && ranges[i].overlaps(range) { throw BusError.overlap(range) }
        ranges.insert(range, at: i)
        devices.insert(device, at: i)
    }

    public func Remove(at base: uint64) {
        if let i = ranges.firstIndex(where: { $0.Base == base }) {
            ranges.remove(at: i)
            devices.remove(at: i)
        }
    }

    /// The device covering `address`, and the offset into its range.
    public func Find(_ address: uint64) -> PioMatch? {
        var lo = 0
        var hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].End <= address {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < ranges.count && ranges[lo].Base <= address {
            return PioMatch(dev: devices[lo], offset: address - ranges[lo].Base)
        }
        return nil
    }
}
