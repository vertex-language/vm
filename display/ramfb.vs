package display

import (
    "encoding/binary"
    "vm/boot"
    "vm/device"
)

/// ramfb: a framebuffer in ordinary guest RAM, configured by one fw_cfg
/// file ("etc/ramfb") the firmware writes: address, fourcc, flags, width,
/// height, stride, all big-endian. EDK2's QemuRamfbDxe sets it up and
/// exposes it as GOP; the OS then draws into the same memory.
public final class Ramfb {
    public let Framebuffer: Framebuffer

    static let fourccXrgb8888: uint32 = 0x3432_5258   // "XR24"

    /// Registers "etc/ramfb" with the machine's fw_cfg.
    public init(memory: device.GuestMemory, fwcfg: boot.FwCfg) {
        Framebuffer = display.Framebuffer(memory: memory)
        let fb = Framebuffer
        fwcfg.Add(boot.FwCfg.File(name: "etc/ramfb", bytes: [uint8](repeating: 0, count: 28), onWrite: { cfg in
            if cfg.count < 28 { return }
            let be = binary.BigEndian.self
            let addr = be.Uint64(cfg, from: 0)
            let fourcc = be.Uint32(cfg, from: 8)
            let width = int(be.Uint32(cfg, from: 16))
            let height = int(be.Uint32(cfg, from: 20))
            let stride = int(be.Uint32(cfg, from: 24))
            let format: Format = fourcc == Ramfb.fourccXrgb8888 ? .xrgb8888 : .xbgr8888
            fb.Configure(address: device.GuestAddress(addr), width: width, height: height, stride: stride, format: format)
        }))
    }
}
