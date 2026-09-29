# vm/disk

What disk devices read and write.

| Package | What it is |
| :--- | :--- |
| **`vm/disk`** | the `Image` protocol; `Raw` files (and ISOs, read-only); `MemoryImage` for tests |
| **`vm/disk/qcow2`** | QCOW2 v2/v3: L1/L2 tables, refcounts, copy-on-write, backing files |
| **`vm/disk/vhdx`** | VHDX: Hyper-V's format, the one Windows images come in |

`virtio.Block`, `nvme.Namespace` and `usb.Storage` all take an `Image`, so any
format works with any device. `vm.OpenDisk(path)` picks the format from the
file's magic number. That sniffing lives in the root package, because
`disk` can't import its own children.
