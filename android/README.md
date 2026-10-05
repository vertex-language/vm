# vm/android

Boots the Android emulator's system images: Google's plain-AOSP builds (no Google services) that [`vmimage`](../../vmimage) pulls and clones, on the emulator's "ranchu" board as vm models it. Android 5–7.1 (API 21–25) boot to their launcher; 8.0 (API 26) and 9 (API 28) too, drawing through vm's host renderer (`--gles`, `vm/gfxstream`). Android 9 boots with system.img as its root file system (`SystemAsRoot`) and no ramdisk.

```vertex
import "vm/android"
```

## Types

- **`AndroidError`** (enum): Not a bundle, or a release vm can't boot yet.
- **`BootProperties`** (struct): What the emulator tells Android at boot (Java heap, screen density, navigation bar): `RamdiskLines`, read at startup, go in the ramdisk; `ServiceLines` through qemud. `Ethernet`: eth0 as the device's network, through Android's EthernetService (Android 5–8: the feature file in the ramdisk; Android 9: on an /oem partition, below). `HostGpu`: draw through the host renderer. `ForScreen(width:)` picks them for a screen size.
- **`BootPropertiesService`** (class): qemud's `boot-properties` service, on the goldfish pipe.
- **`LogcatService`** (class): the emulator's `logcat` pipe service: the device's log as lines of text.
- **`Bundle`** (struct): An unpacked emulator image: its directory, API level and release, `Kernel` (`kernel-ranchu`), `Ramdisk`, the `Disks` in the order its `fstab.ranchu` names them (system, cache, userdata), `Cmdline()`, the kernel command line the emulator gives it, and `BootRamdisk(_:)`, the ramdisk with `BootProperties` added to its `default.prop` (a second cpio archive after the image's own). `OpenDisks(_:)` opens the disks, and `FirstStageMounts(_:)` is what init's first stage mounts from the device tree. Android 9 has no ramdisk, so with `Ethernet` its vendor disk is presented as a GPT disk of two partitions (`disk.GptDisk`): `vendor`, read from vendor.img, and `oem`, an ext4 made in memory (`fs/ext4`) holding `OemFiles`, mounted at /oem. A disk of its own would be vdf, which the vendor's fstab gives vold as the SD card.

## Use

`vm-run --android <dir>` reads the bundle, sets `Config.Guest = .android` (goldfish screen, input and battery instead of VirtIO input), and boots the kernel directly; old kernels get legacy VirtIO MMIO automatically. See the repository [README](../README.md#android).
