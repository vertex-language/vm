package android

import (
    "archive/cpio"
    "compress/gzip"
    "fs"
    "io"
)

/// What the emulator would tell Android at boot through its qemud
/// "boot-properties" service, which vm doesn't have: without them the
/// Java heap is the runtime's 16 MB default (the launcher runs out of
/// memory opening its app drawer), SurfaceFlinger has no density, and
/// there's no navigation bar.
public struct BootProperties {
    /// dalvik.vm.heapsize, in MB.
    public var HeapMb: int = 256
    /// ro.sf.lcd_density: 320 (xhdpi) for a 720-wide screen.
    public var Density: int = 320
    /// The on-screen Back / Home / Recents bar (qemu.hw.mainkeys=0).
    public var NavigationBar: bool = true

    public init() {}

    /// For a screen `width` pixels wide, the density the emulator's
    /// skins of that size use.
    public static func ForScreen(width: int) -> BootProperties {
        var p = BootProperties()
        p.Density = width >= 1080 ? 420 : width >= 720 ? 320 : width >= 480 ? 240 : 160
        p.HeapMb = width >= 1080 ? 512 : 256
        return p
    }

    var lines: [string] {
        ["dalvik.vm.heapsize=\(HeapMb)m", "ro.sf.lcd_density=\(Density)",
         "qemu.hw.mainkeys=\(NavigationBar ? 0 : 1)"]
    }
}

extension Bundle {
    /// The ramdisk to boot: the image's own, followed by a small cpio
    /// archive whose default.prop is the image's plus `props`. Linux
    /// unpacks concatenated initramfs archives in order, so the later
    /// default.prop replaces the first; the image's file is not changed.
    public func BootRamdisk(_ props: BootProperties) throws -> [uint8] {
        let original = try fs.ReadFile(fs.Path(Ramdisk))
        var defaults = ""
        // Only a gzip'd ramdisk is read (Android 5–7.1); otherwise the
        // properties stand alone.
        if original.count > 2 && original[0] == 0x1f && original[1] == 0x8b {
            let cpioBytes = try gzip.Decompress(original)
            var r = cpio.Reader(io.Cursor(cpioBytes))
            while let h = try r.Next() {
                if h.Name == "default.prop" || h.Name == "./default.prop" {
                    defaults = string(decoding: try r.ReadAll(), as: UTF8.self)
                    break
                }
            }
        }
        var text = defaults
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "# vm: what the emulator's boot-properties service would set\n"
        for l in props.lines { text += l + "\n" }
        let data = [uint8](text.utf8)

        var w = cpio.Writer(io.Cursor())
        try w.WriteHeader(cpio.Header(name: "default.prop", mode: cpio.ModeType.regular | 0o644, size: int64(data.count)))
        try w.Write(data)
        try w.Close()

        var out = original
        // The next archive starts on a four-byte boundary; zeros between are skipped.
        while out.count % 4 != 0 { out.append(0) }
        out.append(contentsOf: w.Inner.Bytes)
        return out
    }
}
