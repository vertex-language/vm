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
        }
    }

    public var Configured: bool { lock.withLock { Width > 0 && Height > 0 } }

    /// Bumped each time the mode changes, so a viewer knows to resize.
    public var Generation: uint64 { lock.withLock { generation } }

    /// Copies the visible pixels out as tightly packed RGBA rows, for
    /// ui/window's Present.
    public func Snapshot() throws -> [uint8] {
        let (addr, w, h, stride, fmt, hostPtr) = lock.withLock {
            (Address, Width, Height, Stride, Format, HostPointer)
        }
        if w <= 0 || h <= 0 { return [] }
        var out = [uint8](repeating: 0, count: w * h * 4)

        if let ptr = hostPtr {
            let p = UnsafePointer<uint8>(ptr)
            for y in 0..<h {
                let rowOffset = y * stride
                let dstRow = y * w * 4
                if fmt == .xrgb8888 {
                    var x = 0
                    while x < w {
                        let srcIdx = rowOffset + x * 4
                        let dstIdx = dstRow + x * 4
                        out[dstIdx] = p[srcIdx + 2]     // R
                        out[dstIdx + 1] = p[srcIdx + 1] // G
                        out[dstIdx + 2] = p[srcIdx]     // B
                        out[dstIdx + 3] = 255           // A
                        x += 1
                    }
                } else {
                    for x in 0..<(w * 4) {
                        out[dstRow + x] = p[rowOffset + x]
                    }
                }
            }
            return out
        }

        for y in 0..<h {
            let row = try memory.Read(addr.Adding(uint64(y * stride)), count: w * 4)
            let dstRow = y * w * 4
            if fmt == .xrgb8888 {
                var x = 0
                while x < w {
                    let srcIdx = x * 4
                    let dstIdx = dstRow + srcIdx
                    out[dstIdx] = row[srcIdx + 2]
                    out[dstIdx + 1] = row[srcIdx + 1]
                    out[dstIdx + 2] = row[srcIdx]
                    out[dstIdx + 3] = 255
                    x += 1
                }
            } else {
                for i in 0..<row.count {
                    out[dstRow + i] = row[i]
                }
            }
        }
        return out
    }

    /// Converts the current framebuffer snapshot into a standard image.RGBA.
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
