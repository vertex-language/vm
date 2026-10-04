package display

import (
    "sync"
    "vm/device"
)

/// The Android emulator's framebuffer ("generic,goldfish-fb"), which the
/// goldfish kernels before 4.x drive as /dev/graphics/fb0. The driver
/// reads the size, allocates the pixels in its own RAM (two screens, to
/// flip between) and writes where the visible one starts to SET_BASE,
/// then waits for the BASE_UPDATE_DONE interrupt. Pixels are RGB565.
public final class GoldfishFb: device.Mmio {
    public static let Size: uint64 = 0x100

    // Registers (drivers/video/fbdev/goldfishfb.c).
    static let getWidth: uint64 = 0x00
    static let getHeight: uint64 = 0x04
    static let intStatus: uint64 = 0x08
    static let intEnable: uint64 = 0x0c
    static let setBase: uint64 = 0x10
    static let setRotation: uint64 = 0x14
    static let setBlank: uint64 = 0x18
    static let getPhysWidth: uint64 = 0x1c
    static let getPhysHeight: uint64 = 0x20
    static let getFormat: uint64 = 0x24

    static let intVsync: uint32 = 1 << 0
    static let intBaseUpdateDone: uint32 = 1 << 1
    /// HAL_PIXEL_FORMAT_RGB_565.
    static let formatRgb565: uint64 = 4

    public let Framebuffer: Framebuffer
    public let Width: int
    public let Height: int
    /// The screen's physical size in millimetres, which sets Android's density.
    public let WidthMm: int
    public let HeightMm: int
    let irq: any device.Irq
    let lock = sync.Mutex()
    var status: uint32 = 0
    var enabled: uint32 = 0

    public init(memory: device.GuestMemory, irq: any device.Irq, width: int, height: int, dpi: int = 160) {
        Framebuffer = display.Framebuffer(memory: memory)
        self.irq = irq
        Width = width
        Height = height
        WidthMm = width * 254 / (dpi * 10)
        HeightMm = height * 254 / (dpi * 10)
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        lock.withLock {
            switch offset {
            case GoldfishFb.getWidth: return uint64(Width)
            case GoldfishFb.getHeight: return uint64(Height)
            case GoldfishFb.intStatus:
                let s = status
                status = 0
                irq.Set(false)
                return uint64(s)
            case GoldfishFb.getPhysWidth: return uint64(WidthMm)
            case GoldfishFb.getPhysHeight: return uint64(HeightMm)
            case GoldfishFb.getFormat: return GoldfishFb.formatRgb565
            default: return 0
            }
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        lock.withLock {
            switch offset {
            case GoldfishFb.intEnable:
                enabled = uint32(truncatingIfNeeded: value)
                update()
            case GoldfishFb.setBase:
                Framebuffer.Configure(address: device.GuestAddress(size == 8 ? value : value & 0xffff_ffff), width: Width, height: Height,
                                      stride: Width * 2, format: .rgb565)
                status |= GoldfishFb.intBaseUpdateDone
                update()
            default:
                break
            }
        }
    }

    /// A vsync: Android's display paces itself on it where it asks.
    public func Vsync() {
        lock.withLock {
            status |= GoldfishFb.intVsync
            update()
        }
    }

    func update() {
        irq.Set(status & enabled != 0)
    }
}
