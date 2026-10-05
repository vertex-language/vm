// Package android boots the Android emulator's system images: the
// bundles `vmimage --clone android:<release>` makes (Google's
// `sys-img/android` zips, unpacked), on the emulator's "ranchu" board as
// vm models it — goldfish devices for the screen and input, VirtIO for
// the disks.
package android

import (
    "archive/cpio"
    "compress/gzip"
    "fs"
    "io"
    "vm"
)

public enum AndroidError: Error, CustomStringConvertible {
    case notABundle(string)
    case unsupported(api: int, why: string)

    public var description: string {
        switch self {
        case .notABundle(let d): return "\(d) is not an Android emulator image (no kernel-ranchu, ramdisk.img and system.img); make one with `vmimage --clone android:5 <dir>`"
        case .unsupported(let api, let why): return "Android API \(api) doesn't boot here yet: \(why)"
        }
    }
}

/// A disk the guest sees, and the GPT partition on it that holds the
/// filesystem, if it has one (Android 8's system.img and vendor.img).
public struct Disk {
    public let Path: string
    public let Partition: string?
}

/// An unpacked emulator image, ready to boot.
public struct Bundle {
    public let Dir: string
    /// The API level (21 is Android 5.0), from source.properties.
    public let ApiLevel: int
    /// "5.0.2", from build.prop, or "".
    public let Release: string
    public var Kernel: string { Dir + "/kernel-ranchu" }
    public var Ramdisk: string { Dir + "/ramdisk.img" }
    /// The disks in the order the image's fstabs name them: vda, vdb, …
    public let Disks: [Disk]
    /// What Android 8+ mounts in its first stage (the image's
    /// fstab.ranchu.early), for the device tree.
    public let EarlyMounts: [vm.AndroidMount]
    /// Android 9+: the kernel mounts system.img as the root file system
    /// and runs its init; there is no ramdisk.
    public let SystemAsRoot: bool

    /// Reads the bundle in `dir`.
    public static func Open(_ dir: string) throws -> Bundle {
        let d = dir.hasSuffix("/") ? string(dir.dropLast()) : dir
        for f in ["kernel-ranchu", "ramdisk.img", "system.img"] where !fs.Exists(fs.Path(d + "/" + f)) {
            throw AndroidError.notABundle(d)
        }
        let props = properties((try? fs.ReadText(fs.Path(d + "/source.properties"))) ?? "")
        let build = properties((try? fs.ReadText(fs.Path(d + "/build.prop"))) ?? "")
        let api = int(props["AndroidVersion.ApiLevel"] ?? build["ro.build.version.sdk"] ?? "") ?? 0
        if api >= 29 {
            throw AndroidError.unsupported(api: api, why: "Android 10 and later boot from a super partition with verified-boot (vbmeta) arguments; vm runs Android 5–9 (API 21–28) so far")
        }
        for f in ["cache.img", "userdata.img"] where !fs.Exists(fs.Path(d + "/" + f)) {
            throw AndroidError.notABundle(d + " (no \(f): make the directory with `vmimage --clone`)")
        }
        let file = { (name: string) -> Disk in Disk(Path: d + "/" + name, Partition: nil) }
        var disks = [file("system.img"), file("cache.img"), file("userdata.img")]
        var early: [vm.AndroidMount] = []
        if api >= 28 {
            // Android 9 (the vendor's fstab.ranchu and the emulator's
            // order): system (the root), cache, userdata, the key disk
            // userdata's encryption keeps its footer on, vendor; vendor
            // is mounted in init's first stage, from the device tree.
            for f in ["vendor.img", "encryptionkey.img"] where !fs.Exists(fs.Path(d + "/" + f)) {
                throw AndroidError.notABundle(d + " (no \(f))")
            }
            disks = [Disk(Path: d + "/system.img", Partition: "system"), file("cache.img"), file("userdata.img"),
                     file("encryptionkey.img"), Disk(Path: d + "/vendor.img", Partition: "vendor")]
            early = earlyMounts("/dev/block/vde /vendor ext4 ro,barrier=1 wait", disks)
        } else if api >= 26 {
            // Android 8–8.1 (fstab.ranchu.early, fstab.ranchu): system,
            // cache, userdata, vendor; system and vendor are GPT disks of
            // one partition each, mounted in init's first stage.
            if !fs.Exists(fs.Path(d + "/vendor.img")) { throw AndroidError.notABundle(d + " (no vendor.img)") }
            disks = [Disk(Path: d + "/system.img", Partition: "system"), file("cache.img"), file("userdata.img"),
                     Disk(Path: d + "/vendor.img", Partition: "vendor")]
            early = earlyMounts(ramdiskFiles(d + "/ramdisk.img", ["fstab.ranchu.early"])["fstab.ranchu.early"] ?? "", disks)
        }
        return Bundle(Dir: d, ApiLevel: api, Release: build["ro.build.version.release"] ?? "", Disks: disks, EarlyMounts: early,
                      SystemAsRoot: api >= 28)
    }

    /// The kernel command line the emulator would give this image: the
    /// console on the PL011, the ranchu board's init scripts, software
    /// rendering (no host GL behind a pipe), SELinux permissive (eng
    /// builds allow it; the policy knows none of vm's devices).
    /// `hostGpu`: the guest draws through the host's renderer (qemu.gles=1).
    /// Android 9 boots its root from system.img's partition, and reads the
    /// properties it can't get from a ramdisk here (`props.CmdlineArgs`).
    public func Cmdline(console: bool = true, hostGpu: bool = false, props: BootProperties = BootProperties()) -> string {
        var c = "androidboot.hardware=ranchu qemu=1 qemu.gles=\(hostGpu ? 1 : 0) androidboot.selinux=permissive"
        if console { c = "console=ttyAMA0,38400 androidboot.console=ttyAMA0 " + c }
        if SystemAsRoot {
            c += " skip_initramfs rootwait ro init=/init root=/dev/vda1"
            for a in props.CmdlineArgs { c += " " + a }
        }
        return c
    }
}

/// The named files of a gzip'd ramdisk, as text.
func ramdiskFiles(_ path: string, _ names: [string]) -> [string: string] {
    var out: [string: string] = [:]
    guard let raw = try? fs.ReadFile(fs.Path(path)), raw.count > 2, raw[0] == 0x1f, raw[1] == 0x8b,
          let bytes = try? gzip.Decompress(raw) else { return out }
    var r = cpio.Reader(io.Cursor(bytes))
    while let h = try? r.Next() {
        let name = h.Name.hasPrefix("./") ? string(h.Name.dropFirst(2)) : h.Name
        if names.contains(name), let data = try? r.ReadAll() {
            out[name] = string(decoding: data, as: UTF8.self)
        }
    }
    return out
}

/// An fstab's lines as first-stage mounts: "/dev/block/vda /system ext4
/// ro wait". Android 8's first stage waits for a device whose partition
/// name is the device path's last part, so a disk with a GPT partition
/// is named by its by-name link: /dev/block/platform/<the disk's
/// virtio-mmio device>/by-name/<partition>, as init makes it.
func earlyMounts(_ fstab: string, _ disks: [Disk]) -> [vm.AndroidMount] {
    var out: [vm.AndroidMount] = []
    for line in fstab.split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map { string($0) }
        if f.count < 5 || f[0].hasPrefix("#") || !f[1].hasPrefix("/") { continue }
        var dev = f[0]
        // /dev/block/vdX is the X'th disk: virtio-mmio slot X (disks come first).
        if dev.hasPrefix("/dev/block/vd") && dev.count == 14, let c = dev.utf8.last, c >= 0x61, c <= 0x7a {
            let slot = int(c - 0x61)
            if slot < disks.count, let part = disks[slot].Partition {
                dev = byName(slot: slot, partition: part)
            }
        }
        out.append(vm.AndroidMount(name: string(f[1].dropFirst()), device: dev, fsType: f[2], mountFlags: f[3], fsmgrFlags: f[4]))
    }
    return out
}

/// The by-name link init makes for `partition` of the disk in virtio-mmio `slot`.
func byName(slot: int, partition: string) -> string {
    let addr = vm.PlatformArm64.VirtioMmioBase + uint64(slot) * vm.PlatformArm64.VirtioMmioStride
    return "/dev/block/platform/\(string(addr, radix: 16)).virtio_mmio/by-name/\(partition)"
}

/// `key=value` lines.
func properties(_ text: string) -> [string: string] {
    var out: [string: string] = [:]
    for line in text.split(separator: "\n") {
        let l = string(line)
        if l.hasPrefix("#") { continue }
        if let eq = l.firstIndex(of: "=") {
            var v = string(l[l.index(after: eq)...])
            while v.hasSuffix("\r") || v.hasSuffix(" ") { v = string(v.dropLast()) }
            out[string(l[..<eq])] = v
        }
    }
    return out
}
