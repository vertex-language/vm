package acpi

/// The Serial Port Console Redirection table: which UART is the console.
/// Windows' Emergency Management Services and Linux's earlycon read it.
public enum UartKind: uint8 {
    case ns16550 = 0
    case pl011 = 3
}

public func Spcr(kind: UartKind, address: uint64, irq: uint32, io: bool) -> [uint8] {
    var t = Table(signature: "SPCR", revision: 2)
    t.U8(kind.rawValue)
    t.Zeroes(3)
    // A PL011's registers are 32 bits wide; byte access to them is undefined.
    let wide = kind == .pl011
    t.Gas(space: io ? AddressSpace.io : AddressSpace.memory, bitWidth: wide ? 32 : 8,
          accessSize: wide ? 3 : 1, address: address)
    t.U8(io ? 0x1 : 0x8)                       // interrupt type: 8259-style or GIC
    t.U8(io ? uint8(irq) : 0)                  // IRQ
    t.U32(irq)                                 // global system interrupt
    t.U8(7)                                    // 115200 baud
    t.U8(0); t.U8(1); t.U8(0)                  // parity none, 1 stop bit, no flow control
    t.U8(0)                                    // terminal type VT100
    t.U8(0)
    t.U16(0xffff); t.U16(0xffff)               // not a PCI device
    t.U8(0); t.U8(0); t.U8(0)
    t.U32(0)
    t.U8(0)
    t.Zeroes(4)
    return t.Finish()
}
