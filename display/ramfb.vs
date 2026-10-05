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
        let fb = display.Framebuffer(memory: memory)
        self.Framebuffer = fb
        Ramfb.register(fwcfg: fwcfg, fb: fb)
    }

    static func register(fwcfg: boot.FwCfg, fb: Framebuffer) {
        fwcfg.Add(boot.FwCfg.File(name: "etc/ramfb", bytes: [uint8](repeating: 0, count: 28), onWrite: { cfg in
            Ramfb.handleWrite(cfg: cfg, fb: fb)
        }))
    }

    static func handleWrite(cfg: [uint8], fb: Framebuffer) {
        if cfg.count < 28 { return }
        let addr = binary.BigEndian.Uint64(cfg, from: 0)
        let fourcc = binary.BigEndian.Uint32(cfg, from: 8)
        let width = int(binary.BigEndian.Uint32(cfg, from: 16))
        let height = int(binary.BigEndian.Uint32(cfg, from: 20))
        let stride = int(binary.BigEndian.Uint32(cfg, from: 24))
        let format: Format = (fourcc == Ramfb.fourccXrgb8888) ? .xrgb8888 : .xbgr8888
        print("[ramfb] GOP Framebuffer configured: \(width)x\(height) addr=0x\(string(addr, radix: 16)) stride=\(stride) format=\(format)")
        fb.Configure(address: device.GuestAddress(addr), width: width, height: height, stride: stride, format: format)
    }
}
