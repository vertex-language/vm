// Package disk is what a disk device reads and writes: the Image protocol,
// and raw files. Formats with structure (qcow2, vhdx) are the packages
// under it and return Images too.
package disk

/// A virtual disk's bytes, however they're stored.
///
/// Offsets and counts are in bytes. Devices address sectors, so they
/// multiply by 512 (or their logical block size) before calling.
public protocol Image: AnyObject {
    /// The size the guest sees, in bytes.
    var Size: uint64 { get }
    var ReadOnly: bool { get }
    /// Reads buffer.count bytes at offset. Unallocated parts of a sparse
    /// image read as zeroes.
    func ReadAt(_ offset: uint64, into buffer: inout [uint8]) async throws
    func WriteAt(_ offset: uint64, _ bytes: borrowing [uint8]) async throws
    /// Makes everything written so far durable.
    func Flush() async throws
    /// The guest no longer needs these bytes (TRIM / DISCARD / DEALLOCATE).
    /// An image may free the space, or do nothing.
    func Discard(_ offset: uint64, count: uint64) async throws
    func Close()
}

/// DiskError is every way an image refuses.
public enum DiskError: Error, CustomStringConvertible {
    /// The bytes aren't the format they were opened as.
    case badFormat(string)
    /// A feature of the format this package doesn't implement.
    case unsupported(string)
    case readOnly(string)
    case outOfRange(offset: uint64, count: uint64)
    /// The image's own structures disagree with each other.
    case corrupt(string)
    case io(string)

    public var description: string {
        switch self {
        case .badFormat(let what):
            return "not a disk image: \(what)"
        case .unsupported(let what):
            return "unsupported: \(what)"
        case .readOnly(let what):
            return "read-only: \(what)"
        case .outOfRange(let off, let n):
            return "\(n) bytes at \(off) are past the end of the disk"
        case .corrupt(let what):
            return "corrupt image: \(what)"
        case .io(let what):
            return "disk I/O: \(what)"
        }
    }
}

/// Checks that a request lies inside an image.
public func CheckRange(_ image: any Image, _ offset: uint64, _ count: uint64) throws {
    if count > image.Size || offset > image.Size - count {
        throw DiskError.outOfRange(offset: offset, count: count)
    }
}
