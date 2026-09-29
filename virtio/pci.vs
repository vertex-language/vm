package virtio

import (
    "vm/device"
    "vm/pci"
)

/// VirtIO over PCI (spec §4.1): the standard platform's transport. PCI
/// device ID 0x1040 + the VirtIO ID, and vendor-specific capabilities
/// pointing at the common, notify, ISR and device config structures in
/// BAR 4. Interrupts are MSI-X: one vector for config, one per queue.
public final class PciTransport: pci.Function, Notifier {
    let dev: any Device
    let memory: device.GuestMemory
    public let Config: pci.ConfigSpace
    var queues: [Queue]
    var msix: pci.MsixTable

    public init(_ dev: any Device, memory: device.GuestMemory, msi: any device.Msi) {
        self.dev = dev
        self.memory = memory
        queues = dev.QueueSizes.enumerated().map { Queue(index: $0.offset, size: $0.element, memory: memory) }
        msix = pci.MsixTable(vectors: dev.QueueSizes.count + 1, msi: msi)
        Config = pci.ConfigSpace(
            vendor: 0x1af4,
            device: 0x1040 + uint16(dev.Id.rawValue),
            classCode: pci.ClassCode.forVirtio(dev.Id.rawValue),
            revision: 1
        )
        // TODO(P4): BAR 4 (64-bit memory, 16 KiB): common cfg @0, ISR @0x1000,
        // device cfg @0x2000, notify @0x3000 with a multiplier of 4; the
        // five vendor capabilities (cfg_type 1..5) and the MSI-X capability.
    }

    public var Bars: [pci.Bar] {
        [pci.Bar(index: 4, size: 0x4000, kind: .memory64, prefetchable: false)]
    }

    public func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64 {
        // TODO(P4): common configuration structure, ISR, device config, MSI-X table.
        0
    }

    public func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64) {
        // TODO(P4): as ReadBar; a write in the notify region kicks queue offset / 4.
    }

    public func QueueUsed(_ index: int) {
        msix.Signal(index + 1)
    }

    public func ConfigChanged() {
        msix.Signal(0)
    }
}
