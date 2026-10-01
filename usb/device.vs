// Package usb is an xHCI controller and the USB devices a guest needs
// without extra drivers: a HID keyboard, a HID tablet (absolute pointer),
// and mass storage for installer ISOs. Windows, Linux, the BSDs and UEFI
// all have inbox drivers for every one of them.
package usb

/// A SETUP packet (USB 2.0 §9.3).
public struct Setup {
    public let RequestType: uint8
    public let Request: uint8
    public let Value: uint16
    public let Index: uint16
    public let Length: uint16

    public init(requestType: uint8, request: uint8, value: uint16, index: uint16, length: uint16) {
        RequestType = requestType
        Request = request
        Value = value
        Index = index
        Length = length
    }

    public var DeviceToHost: bool { RequestType & 0x80 != 0 }
    /// Standard (0), class (1) or vendor (2).
    public var Kind: uint8 { (RequestType >> 5) & 3 }
    /// Device (0), interface (1), endpoint (2) or other (3).
    public var Recipient: uint8 { RequestType & 0x1f }
}

/// The result of a transfer.
public enum Transfer {
    case data([uint8])
    /// Nothing to send yet (an interrupt endpoint with no new report).
    case nak
    case stall
}

/// A USB device behind a root-hub port. Control transfers go to endpoint
/// 0; `In` / `Out` to its other endpoints, by endpoint number.
///
/// Not `Device`: vsc confuses protocols that two imported modules both
/// name (vsc_TODO.md).
public protocol Peripheral: AnyObject {
    /// The device descriptor, then the whole configuration descriptor set.
    var DeviceDescriptor: [uint8] { get }
    var ConfigurationDescriptor: [uint8] { get }
    /// The product name its string descriptor 2 gives.
    var Product: string { get }
    /// Speed the port reports: 1 full, 2 low, 3 high, 4 super.
    var Speed: uint8 { get }
    /// Set by the controller: call it when an endpoint that answered
    /// `.nak` has something now.
    var OnData: (() -> Void)? { get set }
    /// Class-specific and vendor control requests, and standard requests
    /// to an interface or endpoint. Standard requests to the device are
    /// the controller's.
    func Control(_ setup: Setup, _ data: [uint8]) -> Transfer
    func In(endpoint: uint8, max: int) async -> Transfer
    func Out(endpoint: uint8, _ data: [uint8]) async -> Transfer
    /// The bus reset the device on its port.
    func Reset()
}

/// Standard descriptor helpers.
func deviceDescriptor(vendor: uint16, product: uint16, deviceClass: uint8 = 0, usb: uint16 = 0x0200, maxPacket0: uint8 = 64) -> [uint8] {
    [18, 1, uint8(usb & 0xff), uint8(usb >> 8), deviceClass, 0, 0, maxPacket0,
     uint8(vendor & 0xff), uint8(vendor >> 8), uint8(product & 0xff), uint8(product >> 8),
     0x00, 0x01, 1, 2, 3, 1]
}

/// A string descriptor: UTF-16LE, as USB wants.
func stringDescriptor(_ s: string) -> [uint8] {
    var b: [uint8] = [0, 3]
    for u in s.unicodeScalars {
        let v = u.value
        if v > 0xffff { continue }   // outside the BMP: not in our names
        b.append(uint8(v & 0xff))
        b.append(uint8(v >> 8))
    }
    b[0] = uint8(b.count)
    return b
}

/// Vertex's USB vendor ID placeholder. TODO: a real VID, or the
/// "pid.codes" open-source VID with an allocated product ID.
let vendorId: uint16 = 0x1209
