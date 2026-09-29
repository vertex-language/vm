// Package pci is a PCI Express root complex for guests: the ECAM
// configuration window, bus 0, BAR placement, INTx routing and MSI-X.
// Devices on the standard platform (virtio-pci, nvme, xhci) implement
// Function and never see the bus.
package pci

/// What a BAR maps.
public enum BarKind: int32 { case memory32 = 0, memory64 = 1, io = 2 }

/// One base address register a function asks for.
public struct Bar {
    public let Index: int
    /// A power of two, at least 16 bytes (4 KiB is what's worth using).
    public let Size: uint64
    public let Kind: BarKind
    public let Prefetchable: bool

    public init(index: int, size: uint64, kind: BarKind, prefetchable: bool) {
        Index = index
        Size = size
        Kind = kind
        Prefetchable = prefetchable
    }
}

/// A PCI function: its configuration space, the BARs it wants, and what
/// happens when the guest touches them.
///
/// Like `device.Mmio`, BAR access runs on a vCPU thread, synchronously.
public protocol Function: AnyObject {
    var Config: ConfigSpace { get }
    var Bars: [Bar] { get }
    func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64
    func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64)
}
