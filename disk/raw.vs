package disk

import "fs"

/// A disk that is a plain file, byte for byte. ISOs are raw images opened
/// read-only.
public final class Raw: Image {
    let file: fs.File
    public let Size: uint64
    public let ReadOnly: bool

    init(file: fs.File, size: uint64, readOnly: bool) {
        self.file = file
        Size = size
        ReadOnly = readOnly
    }

    public func ReadAt(_ offset: uint64, into buffer: inout [uint8]) async throws {
        try CheckRange(self, offset, uint64(buffer.count))
        // TODO: run on sync.ThreadPoolExecutor.Shared; fs.File is synchronous.
        var done = 0
        while done < buffer.count {
            var chunk = [uint8](repeating: 0, count: buffer.count - done)
            let n = try file.Read(into: &chunk, at: int64(offset) + int64(done))
            if n <= 0 {
                break   // a short file reads as zeroes past its end
            }
            for i in 0..<n {
                buffer[done + i] = chunk[i]
            }
            done += n
        }
    }

    public func WriteAt(_ offset: uint64, _ bytes: borrowing [uint8]) async throws {
        if ReadOnly { throw DiskError.readOnly(file.Path.Value) }
        try CheckRange(self, offset, uint64(bytes.count))
        try file.Write(bytes, at: int64(offset))
    }

    public func Flush() async throws {
        if ReadOnly { return }
        try file.Sync(dataOnly: true)
    }

    public func Discard(_ offset: uint64, count: uint64) async throws {
        // TODO: punch a hole (fallocate / F_PUNCHHOLE / FSCTL_SET_ZERO_DATA) once fs offers it.
    }

    public func Close() {
        try? file.Close()
    }
}

/// Opens a file as a raw disk.
public func OpenRaw(_ path: fs.Path, readOnly: bool = false) throws -> Raw {
    var options = fs.OpenOptions()
    options.Write = !readOnly
    let file = try fs.Open(path, options)
    let size = uint64(try file.Metadata().Size)
    return Raw(file: file, size: size, readOnly: readOnly)
}

/// Creates a sparse raw disk of `size` bytes, replacing any file there.
public func CreateRaw(_ path: fs.Path, size: uint64) throws -> Raw {
    let file = try fs.Create(path)
    try file.SetLength(int64(size))
    return Raw(file: file, size: size, readOnly: false)
}

/// A disk held in memory, for tests and scratch space.
public final class MemoryImage: Image {
    var bytes: [uint8]
    public let ReadOnly: bool
    public var Size: uint64 { uint64(bytes.count) }

    public init(size: int, readOnly: bool = false) {
        bytes = [uint8](repeating: 0, count: size)
        ReadOnly = readOnly
    }

    public init(bytes: [uint8], readOnly: bool = false) {
        self.bytes = bytes
        ReadOnly = readOnly
    }

    public func ReadAt(_ offset: uint64, into buffer: inout [uint8]) async throws {
        try CheckRange(self, offset, uint64(buffer.count))
        for i in 0..<buffer.count {
            buffer[i] = bytes[int(offset) + i]
        }
    }

    public func WriteAt(_ offset: uint64, _ data: borrowing [uint8]) async throws {
        if ReadOnly { throw DiskError.readOnly("memory image") }
        try CheckRange(self, offset, uint64(data.count))
        for i in 0..<data.count {
            bytes[int(offset) + i] = data[i]
        }
    }

    public func Flush() async throws {}
    public func Discard(_ offset: uint64, count: uint64) async throws {}
    public func Close() {}
}
