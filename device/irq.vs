package device

/// A wired interrupt line into the interrupt controller: a GIC SPI on
/// arm64, an IOAPIC pin on amd64. vm hands each device its own.
public protocol Irq: AnyObject {
    /// Holds the line at `level`: level-triggered devices (PCI INTx, a
    /// UART) raise it until the guest acknowledges.
    func Set(_ level: bool)
    /// Raises and lowers it: an edge.
    func Pulse()
}

/// A message-signalled interrupt: the write a PCI function makes to raise
/// one (MSI, MSI-X). vm routes it to the GIC's MSI frame or the LAPIC.
public protocol Msi: AnyObject {
    func Send(address: uint64, data: uint32)
}

/// An interrupt line that goes nowhere, for tests and devices a guest
/// polls.
public final class NoIrq: Irq {
    public init() {}
    public func Set(_ level: bool) {}
    public func Pulse() {}
}

/// An interrupt line that remembers what was done to it: what cmd/check
/// gives a device to see it raise interrupts.
public final class RecordingIrq: Irq {
    public private(set) var Level = false
    public private(set) var Pulses = 0

    public init() {}
    public func Set(_ level: bool) { Level = level }
    public func Pulse() { Pulses += 1 }
}
