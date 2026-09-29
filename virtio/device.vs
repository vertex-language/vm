// Package virtio is VirtIO 1.2: virtqueues, the MMIO and PCI transports,
// and the devices Linux (and the BSDs, and Windows with virtio-win)
// drive over them.
//
// A device is written once, against Device, and a transport presents it:
// MmioTransport on the micro platform, PciTransport on the standard one.
package virtio

import "vm/device"

/// Device IDs, from the VirtIO 1.2 spec, §5.
public struct DeviceId: Equatable, Hashable {
    public let rawValue: uint32
    public init(rawValue: uint32) { self.rawValue = rawValue }

    public static let net = DeviceId(rawValue: 1)
    public static let block = DeviceId(rawValue: 2)
    public static let console = DeviceId(rawValue: 3)
    public static let entropy = DeviceId(rawValue: 4)
    public static let balloon = DeviceId(rawValue: 5)
    public static let gpu = DeviceId(rawValue: 16)
    public static let input = DeviceId(rawValue: 18)
    public static let vsock = DeviceId(rawValue: 19)
    public static let fs = DeviceId(rawValue: 26)
}

/// Feature bits every device shares (spec §6).
public enum Feature {
    public static let indirectDescriptors: uint64 = 1 << 28
    public static let eventIdx: uint64 = 1 << 29
    /// VIRTIO_F_VERSION_1: a modern device. Every device here sets it.
    public static let version1: uint64 = 1 << 32
    public static let accessPlatform: uint64 = 1 << 33
    public static let ringPacked: uint64 = 1 << 34
    public static let inOrder: uint64 = 1 << 35
}

/// Device status bits the driver writes (spec §2.1).
public enum Status {
    public static let acknowledge: uint8 = 1
    public static let driver: uint8 = 2
    public static let driverOk: uint8 = 4
    public static let featuresOk: uint8 = 8
    public static let needsReset: uint8 = 64
    public static let failed: uint8 = 128
}

/// Vertex's vendor ID in the MMIO transport's VendorID register ("VTX\0").
/// Not QEMU's.
public let VendorId: uint32 = 0x0058_5456

/// What a transport needs from a device. The transport owns feature
/// negotiation, status and queue setup; the device owns its config space
/// and what its queues mean.
public protocol Device: AnyObject {
    var Id: DeviceId { get }
    /// Everything this device can do, common bits included.
    var Features: uint64 { get }
    /// How many queues, and the largest size of each.
    var QueueSizes: [uint16] { get }
    /// Reads and writes the device-specific configuration space.
    func ReadConfig(offset: uint64, size: uint8) -> uint64
    func WriteConfig(offset: uint64, size: uint8, value: uint64)
    /// The driver set DRIVER_OK: the queues are ready, with these features.
    func Activate(queues: [Queue], features: uint64, notify: any Notifier) throws
    /// The driver wrote 0 to status. Stop using the queues.
    func Reset()
    /// Queue `index` was kicked. Called on a vCPU thread: start work, don't
    /// do it here.
    func Notified(queue index: int)
}

/// How a device tells the driver it used buffers or changed its config:
/// the transport's interrupt (an MMIO IRQ line, or an MSI-X vector).
public protocol Notifier: AnyObject {
    func QueueUsed(_ index: int)
    func ConfigChanged()
}

/// What every device's `Features` starts from.
public let CommonFeatures: uint64 = Feature.version1 | Feature.eventIdx | Feature.indirectDescriptors
