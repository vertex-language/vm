// Package display is a guest's screen: a Framebuffer the host reads, and
// ramfb, the simplest device that gives UEFI a GOP framebuffer, which
// Windows' Basic Display driver keeps drawing into after boot.
//
// Showing it is someone else's job: ui/window presents a Framebuffer, and
// a VNC or RDP server could serve one. A headless VM imports no ui.
package display

import (
    "sync"
    "vm/device"
)

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

    public init(memory: device.GuestMemory) {
        self.memory = memory
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

    /// Copies the visible pixels out as tightly packed BGRA rows, for
    /// ui/window's Present.
    ///
    /// ramfb has no damage reporting, so a viewer calls this at its frame
    /// rate. TODO: dirty-page tracking from the hypervisor to skip
    /// unchanged frames.
    public func Snapshot() throws -> [uint8] {
        let (addr, w, h, stride) = lock.withLock { (Address, Width, Height, Stride) }
        var out = [uint8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let row = try memory.Read(addr.Adding(uint64(y * stride)), count: w * 4)
            for i in 0..<row.count {
                out[y * w * 4 + i] = row[i]
            }
        }
        return out
    }
}
