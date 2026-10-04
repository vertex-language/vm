// Package android boots the Android emulator's system images: the
// bundles `vmimage --clone android:<release>` makes (Google's
// `sys-img/android` zips, unpacked), on the emulator's "ranchu" board as
// vm models it — goldfish devices for the screen and input, VirtIO for
// the disks.
package android

import (
    "fs"
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

/// An unpacked emulator image, ready to boot.
public struct Bundle {
    public let Dir: string
    /// The API level (21 is Android 5.0), from source.properties.
    public let ApiLevel: int
    /// "5.0.2", from build.prop, or "".
    public let Release: string
    public var Kernel: string { Dir + "/kernel-ranchu" }
    public var Ramdisk: string { Dir + "/ramdisk.img" }
    /// The disks in the order the image's fstab.ranchu names them: vda, vdb, …
    public let Disks: [string]

    /// Reads the bundle in `dir`.
    public static func Open(_ dir: string) throws -> Bundle {
        let d = dir.hasSuffix("/") ? string(dir.dropLast()) : dir
        for f in ["kernel-ranchu", "ramdisk.img", "system.img"] where !fs.Exists(fs.Path(d + "/" + f)) {
            throw AndroidError.notABundle(d)
        }
        let props = properties((try? fs.ReadText(fs.Path(d + "/source.properties"))) ?? "")
        let build = properties((try? fs.ReadText(fs.Path(d + "/build.prop"))) ?? "")
        let api = int(props["AndroidVersion.ApiLevel"] ?? build["ro.build.version.sdk"] ?? "") ?? 0
        if api >= 26 {
            throw AndroidError.unsupported(api: api, why: "Android 8 and later boot from a vendor partition and verified-boot metadata, and draw through goldfish pipes; vm runs Android 5–7.1 (API 21–25) so far")
        }
        // Android 5–7.1 (fstab.ranchu): system, cache, userdata.
        for f in ["cache.img", "userdata.img"] where !fs.Exists(fs.Path(d + "/" + f)) {
            throw AndroidError.notABundle(d + " (no \(f): make the directory with `vmimage --clone`)")
        }
        return Bundle(Dir: d, ApiLevel: api, Release: build["ro.build.version.release"] ?? "",
                      Disks: [d + "/system.img", d + "/cache.img", d + "/userdata.img"])
    }

    /// The kernel command line the emulator would give this image: the
    /// console on the PL011, the ranchu board's init scripts, software
    /// rendering (no host GL behind a pipe), SELinux permissive (eng
    /// builds allow it; the policy knows none of vm's devices).
    public func Cmdline(console: bool = true) -> string {
        var c = "androidboot.hardware=ranchu qemu=1 qemu.gles=0 androidboot.selinux=permissive"
        if console { c = "console=ttyAMA0,38400 androidboot.console=ttyAMA0 " + c }
        return c
    }
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
