# vm/android

Boots the Android emulator's system images: Google's plain-AOSP builds (no Google services) that [`vmimage`](../../vmimage) pulls and clones, on the emulator's "ranchu" board as vm models it. Android 5–7.1 (API 21–25) for now.

```vertex
import "vm/android"
```

## Types

- **`AndroidError`** (enum): Not a bundle, or a release vm can't boot yet.
- **`BootProperties`** (struct): What the emulator's qemud boot-properties service would set (Java heap, screen density, navigation bar); `ForScreen(width:)` picks them for a screen size.
- **`Bundle`** (struct): An unpacked emulator image: its directory, API level and release, `Kernel` (`kernel-ranchu`), `Ramdisk`, the `Disks` in the order its `fstab.ranchu` names them (system, cache, userdata), `Cmdline()`, the kernel command line the emulator gives it, and `BootRamdisk(_:)`, the ramdisk with `BootProperties` added to its `default.prop` (a second cpio archive after the image's own).

## Use

`vm-run --android <dir>` reads the bundle, sets `Config.Guest = .android` (goldfish screen, input and battery instead of VirtIO input), and boots the kernel directly; old kernels get legacy VirtIO MMIO automatically. See the repository [README](../README.md#android).
