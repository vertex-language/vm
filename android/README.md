# vm/android

Boots the Android emulator's system images: Google's plain-AOSP builds (no Google services) that [`vmimage`](../../vmimage) pulls and clones, on the emulator's "ranchu" board as vm models it. Android 5–7.1 (API 21–25) for now.

```vertex
import "vm/android"
```

## Types

- **`AndroidError`** (enum): Not a bundle, or a release vm can't boot yet.
- **`Bundle`** (struct): An unpacked emulator image: its directory, API level and release, `Kernel` (`kernel-ranchu`), `Ramdisk`, the `Disks` in the order its `fstab.ranchu` names them (system, cache, userdata), and `Cmdline()`, the kernel command line the emulator gives it.

## Use

`vm-run --android <dir>` reads the bundle, sets `Config.Guest = .android` (goldfish screen, input and battery instead of VirtIO input), and boots the kernel directly; old kernels get legacy VirtIO MMIO automatically. See the repository [README](../README.md#android).
