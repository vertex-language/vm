package android

import (
    "archive/cpio"
    "compress/gzip"
    "fs"
    "io"
)

/// What the emulator tells Android at boot: without them the Java heap is
/// the runtime's 16 MB default (the launcher runs out of memory opening
/// its app drawer), SurfaceFlinger has no density, and there's no
/// navigation bar. Properties read once at startup go in the ramdisk:
/// `ro.*`, which only init may set, and `dalvik.vm.*`, which zygote reads
/// as it starts, sometimes before qemu-props has run (Android 8 starts
/// them together). The rest go through the qemud "boot-properties"
/// service (BootPropertiesService), as on the emulator.
public struct BootProperties {
    /// dalvik.vm.heapsize, in MB.
    public var HeapMb: int = 256
    /// ro.sf.lcd_density: 320 (xhdpi) for a 720-wide screen.
    public var Density: int = 320
    /// The on-screen Back / Home / Recents bar (qemu.hw.mainkeys=0).
    public var NavigationBar: bool = true
    /// eth0 as an Ethernet network apps can use. The emulator's images
    /// get their default network (and with it DNS) from the emulator's
    /// modem; vm has none, so it declares the android.hardware.ethernet
    /// feature (in /oem/etc/permissions, which Android 5+ reads) and the
    /// dhcpcd_eth0 service Android's Ethernet code starts: its
    /// EthernetService then brings eth0 up as the default network, with
    /// the address and DNS the gateway's DHCP gives.
    public var Ethernet: bool = true
    /// Android 8+ draws through the host's renderer (the "opengles"
    /// pipe service, vm/gfxstream) with the emulator's own EGL. Without
    /// it, that EGL is hidden so Android falls back to its software
    /// renderer, which Android 8 can't use for its UI.
    public var HostGpu: bool = false
    /// Android 9+ has no ramdisk: what would go there goes on the kernel
    /// command line (CmdlineArgs) or through qemud.
    public var SystemAsRoot: bool = false

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

    /// The properties qemu-props sets, through the pipe. With no ramdisk,
    /// ro.* go this way too: qemu-props sets them before anyone reads them.
    public var ServiceLines: [string] {
        if SystemAsRoot { return lines.filter { !$0.hasPrefix("dalvik.vm.") } }
        return lines.filter { !readAtStartup($0) }
    }

    /// The properties read once at startup, which go in the ramdisk's default.prop.
    public var RamdiskLines: [string] { SystemAsRoot ? [] : lines.filter { readAtStartup($0) } }

    /// Android 9's kernel command line arguments, which its init reads as
    /// ro.kernel.qemu.*: the Java heap, and the GLES version the host
    /// renderer draws (2.0).
    public var CmdlineArgs: [string] {
        if !SystemAsRoot { return [] }
        return ["qemu.dalvik.vm.heapsize=\(HeapMb)m", "qemu.opengles.version=131072"]
    }

    func readAtStartup(_ line: string) -> bool {
        line.hasPrefix("ro.") || line.hasPrefix("dalvik.vm.")
    }
}

/// The feature file that makes eth0 the device's network.
let ethernetFeature = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- vm: eth0 is the device's network (vm/android BootProperties.Ethernet). -->\n<permissions>\n    <feature name=\"android.hardware.ethernet\" />\n</permissions>\n"

/// For Android 8: its EGL loader takes the emulator's vendor EGL (host
/// GPU through a goldfish pipe, or SwiftShader, which this image lacks)
/// whenever /vendor/lib64/egl is readable, and only falls back to
/// Android's own software renderer when it isn't. vm has neither pipe
/// nor SwiftShader, so the directory is covered by an empty tmpfs no one
/// but root may read: SurfaceFlinger and apps get libGLES_android.
let hideVendorEgl = "\n# vm: no host GPU here: hide the emulator's vendor EGL, so libEGL uses the software renderer.\non init\n    mount tmpfs tmpfs /vendor/lib64/egl mode=0000,uid=0,gid=0\n"

/// The DHCP client Android's Ethernet code starts for eth0, for the device's init script.
let dhcpServices = "\n# vm: the DHCP client Android's Ethernet code starts for eth0.\nservice dhcpcd_eth0 /system/bin/dhcpcd -aABDKL\n    class main\n    disabled\n    oneshot\n\nservice iprenew_eth0 /system/bin/dhcpcd -n\n    class main\n    disabled\n    oneshot\n"

extension Bundle {
    /// The ramdisk to boot: the image's own, followed by a small cpio
    /// archive of files that replace or add to it — default.prop with
    /// `props` added, and for Ethernet, the feature file and the device's
    /// init script with dhcpcd added. Linux unpacks concatenated
    /// initramfs archives in order, so later files replace earlier ones;
    /// the image's file is not changed.
    public func BootRamdisk(_ props: BootProperties) throws -> [uint8] {
        let original = try fs.ReadFile(fs.Path(Ramdisk))
        let rc = "init.ranchu.rc"
        var files: [string: string] = [:]
        // Only a gzip'd ramdisk is read (Android 5–7.1); otherwise the
        // files stand alone.
        if original.count > 2 && original[0] == 0x1f && original[1] == 0x8b {
            let cpioBytes = try gzip.Decompress(original)
            var r = cpio.Reader(io.Cursor(cpioBytes))
            while let h = try r.Next() {
                let name = h.Name.hasPrefix("./") ? string(h.Name.dropFirst(2)) : h.Name
                if (name == "default.prop" || name == rc) && h.Kind == cpio.ModeType.regular {
                    files[name] = string(decoding: try r.ReadAll(), as: UTF8.self)
                }
            }
        }
        var text = files["default.prop"] ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "# vm: boot properties read at startup (the rest come through qemud's boot-properties)\n"
        for l in props.RamdiskLines { text += l + "\n" }

        var w = cpio.Writer(io.Cursor())
        func file(_ name: string, _ content: string, mode: uint32 = 0o644) throws {
            let data = [uint8](content.utf8)
            try w.WriteHeader(cpio.Header(name: name, mode: cpio.ModeType.regular | mode, size: int64(data.count)))
            try w.Write(data)
        }
        func dir(_ name: string) throws {
            try w.WriteHeader(cpio.Header(name: name, mode: cpio.ModeType.directory | 0o755, size: 0))
        }
        try file("default.prop", text)
        // Android 8 reads its defaults from /system/etc/prop.default
        // first (the ramdisk's default.prop only links there), then
        // /odm/default.prop: the properties go there too.
        if ApiLevel >= 26 {
            try dir("odm")
            try file("odm/default.prop", text)
        }
        // Additions to the device's init script.
        var additions = ""
        if props.Ethernet {
            try dir("oem")
            try dir("oem/etc")
            try dir("oem/etc/permissions")
            try file("oem/etc/permissions/android.hardware.ethernet.xml", ethernetFeature)
            // Android 8 gets its address in Java (IpManager); before, Ethernet runs dhcpcd.
            if ApiLevel < 26 { additions += dhcpServices }
        }
        if ApiLevel >= 26 && !props.HostGpu { additions += hideVendorEgl }
        if !additions.isEmpty, let script = files[rc] {
            try file(rc, script + additions, mode: 0o750)
        }
        try w.Close()

        var out = original
        // The next archive starts on a four-byte boundary; zeros between are skipped.
        while out.count % 4 != 0 { out.append(0) }
        out.append(contentsOf: w.Inner.Bytes)
        return out
    }
}
