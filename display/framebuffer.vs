// Package display is a guest's screen: a Framebuffer the host reads, and
// ramfb, the simplest device that gives UEFI a GOP framebuffer, which
// Windows' Basic Display driver keeps drawing into after boot.
//
// Showing it is someone else's job: ui/window presents a Framebuffer, and
// a VNC or RDP server could serve one. A headless VM imports no ui.
package display

import (
    "fs"
    "image"
    "image/png"
    "sync"
    "vm/device"
)

/// Errors that can occur during display/framebuffer operations.
public enum DisplayError: Error {
    case notConfigured
    case emptySnapshot
}

/// Pixel layouts a guest may choose.
public enum Format {
    /// XRGB8888 / B8G8R8X8 little-endian: what UEFI GOP and Windows use.
    case xrgb8888
    case xbgr8888
    case rgb565
}

/// A guest's framebuffer: guest RAM the host reads, and the region that
/// changed since the host last looked.
public final class Framebuffer {
    public private(set) var Width: int = 0
    public private(set) var Height: int = 0
    public private(set) var Stride: int = 0
    public private(set) var Format: Format = .xrgb8888
    public private(set) var Address: device.GuestAddress = device.GuestAddress(0)
    let memory: device.GuestMemory
    let lock = sync.Mutex()
    var generation: uint64 = 0
    var frames: uint64 = 0

    public private(set) var HostPointer: UnsafeMutableRawPointer? = nil

    public init(memory: device.GuestMemory, hostPointer: UnsafeMutableRawPointer? = nil) {
        self.memory = memory
        self.HostPointer = hostPointer
    }

    /// The guest (or its firmware) chose a mode.
    public func Configure(address: device.GuestAddress, width: int, height: int, stride: int, format: Format) {
        lock.withLock {
            Address = address
            Width = width
            Height = height
            Stride = stride
            Format = format
            generation += 1
            frames += 1
        }
    }

    /// The guest showed a new frame without changing the mode (a page
    /// flip to the same buffer).
    public func Post() {
        lock.withLock { frames += 1 }
    }

    /// Bumped for every frame the guest shows, where its device says
    /// (goldfish-fb's SET_BASE): a viewer redraws only when it moves.
    /// Stays 0 for screens the guest draws into in place.
    public var Frames: uint64 { lock.withLock { frames } }

    public var Configured: bool { lock.withLock { Width > 0 && Height > 0 } }

    /// Bumped each time the mode changes, so a viewer knows to resize.
    public var Generation: uint64 { lock.withLock { generation } }

    /// The RGBA buffer Snapshot fills, kept between calls.
    var scratch: [uint8] = []

    /// Copies the visible pixels out as tightly packed RGBA rows, for
    /// ui/window's Present. Reads guest RAM in place through a host
    /// pointer: a viewer calls this every frame, on the thread device
    /// tasks share, so it must stay cheap.
    public func Snapshot() throws -> [uint8] {
        let (addr, w, h, stride, fmt, hostPtr) = lock.withLock {
            (Address, Width, Height, Stride, Format, HostPointer)
        }
        if w <= 0 || h <= 0 { return [] }
        let src = try hostPtr ?? memory.Pointer(addr, count: uint64(stride * h))
        let p = UnsafePointer<uint8>(src.assumingMemoryBound(to: uint8.self))
        if scratch.count != w * h * 4 { scratch = [uint8](repeating: 255, count: w * h * 4) }
        scratch.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let row = p + y * stride
                var d = y * w * 4
                switch fmt {
                case .rgb565:
                    // RRRRRGGG GGGBBBBB, little-endian; widen each to 8 bits.
                    for x in 0..<w {
                        let v = uint32(row[x * 2]) | (uint32(row[x * 2 + 1]) << 8)
                        let r = (v >> 11) & 0x1f
                        let g = (v >> 5) & 0x3f
                        let b = v & 0x1f
                        out[d] = uint8((r << 3) | (r >> 2))
                        out[d + 1] = uint8((g << 2) | (g >> 4))
                        out[d + 2] = uint8((b << 3) | (b >> 2))
                        out[d + 3] = 255
                        d += 4
                    }
                case .xrgb8888:
                    for x in 0..<w {
                        out[d] = row[x * 4 + 2]
                        out[d + 1] = row[x * 4 + 1]
                        out[d + 2] = row[x * 4]
                        out[d + 3] = 255
                        d += 4
                    }
                case .xbgr8888:
                    for x in 0..<w {
                        out[d] = row[x * 4]
                        out[d + 1] = row[x * 4 + 1]
                        out[d + 2] = row[x * 4 + 2]
                        out[d + 3] = 255
                        d += 4
                    }
                }
            }
        }
        return scratch
    }

    public func ToImage() throws -> image.RGBA? {
        let (w, h) = lock.withLock { (Width, Height) }
        if w <= 0 || h <= 0 { return nil }
        let snap = try Snapshot()
        if snap.isEmpty { return nil }
        return image.RGBA(width: w, height: h, pixels: snap)
    }

    /// Encodes the current framebuffer snapshot as a PNG and writes it to disk.
    public func SavePNG(to path: fs.Path) throws {
        guard let img = try ToImage() else {
            throw DisplayError.notConfigured
        }
        let pngBytes = png.Encode(img)
        let file = try fs.Create(path)
        defer { try? file.Close() }
        try file.Write(pngBytes)
    }
}
