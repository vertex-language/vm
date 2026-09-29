# vm/pci

A PCI Express root complex for guests on the standard platform.

- **`Root`**: bus 0 behind an ECAM window. It answers configuration
  cycles, places BARs in the platform's 32- and 64-bit MMIO windows, and
  swizzles INTx.
- **`Function`**: what a device implements. That's a `ConfigSpace`, the
  `Bar`s it wants, and BAR reads and writes.
- **`ConfigSpace`**: the type-0 header and the capability list.
- **`MsixTable`**: MSI-X vectors, masks and the pending-bit array. It
  sends through `device.Msi`.

Windows only enumerates PCI, and UEFI firmware expects it. The micro
profile doesn't use this package at all.
