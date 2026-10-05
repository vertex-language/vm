# vm/disk

What disk devices read and write.

| Package | What it is |
| :--- | :--- |
| **`vm/disk`** | the `Image` protocol; `Raw` files (and ISOs, read-only); `MemoryImage` for tests; ISO 9660 PVD/directory parser, file extraction, and distribution boot file detection (`disk/iso.vs`) |
| **`vm/disk/qcow2`** | QCOW2 v2/v3: L1/L2 tables, refcounts, copy-on-write, backing files |
| **`vm/disk/vhdx`** | VHDX: Hyper-V's format, the one Windows images come in |

`virtio.Block`, `nvme.Namespace` and `usb.Storage` all take an `Image`, so any
format works with any device. `vm.OpenDisk(path)` picks the format from the
file's magic number. That sniffing lives in the root package, because
`disk` can't import its own children.

### ISO 9660 & El Torito Support
- **PVD Parsing**: Reads Primary Volume Descriptors, block size, volume identification, and root directory descriptors.
- **El Torito Boot Catalog**: Detects bootable optical media and verifies boot sector headers.
- **Directory Traversal**: Native sector-by-sector directory parser with ISO 9660 / Rock Ridge name normalization (stripping `;1` version extensions and lowercase conversions).
- **Automated Boot File Detection**: Automatically discovers Linux kernel (`vmlinuz`, `linux`, `Image`) and initramfs (`initrd`, `initrd.gz`, `initramfs`) across Casper (Ubuntu/Mint), Debian installer, Arch, and Fedora disc layouts.
- **Stream Extraction**: Fast chunked file extraction directly from ISO images to the host filesystem.
