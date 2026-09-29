package usb

import (
    "encoding/binary"
    "vm/disk"
)

typealias LE = binary.LittleEndian

/// USB mass storage, bulk-only transport, with the SCSI commands UEFI and
/// OS installers use: INQUIRY, TEST UNIT READY, READ CAPACITY(10/16),
/// READ(10/16), WRITE(10/16), REQUEST SENSE, MODE SENSE. `Removable` makes
/// it a CD-like medium for ISOs.
public final class Storage: Device {
    public let Image: any disk.Image
    public let Removable: bool
    public let BlockSize: uint64
    var pending: [uint8]? = nil      // the CBW waiting for its data phase

    /// ISOs use 2048-byte blocks; disks 512.
    public init(_ image: any disk.Image, removable: bool = true, blockSize: uint64 = 512) {
        Image = image
        Removable = removable
        BlockSize = blockSize
    }

    public var Speed: uint8 { 3 }
    public var DeviceDescriptor: [uint8] { deviceDescriptor(vendor: vendorId, product: 0x0003) }

    public var ConfigurationDescriptor: [uint8] {
        [9, 2, 32, 0, 1, 1, 0, 0x80, 50,
         9, 4, 0, 0, 2, 0x08, 0x06, 0x50, 0,         // mass storage, SCSI transparent, bulk-only
         7, 5, 0x81, 2, 0x00, 0x02, 0,               // bulk IN, 512
         7, 5, 0x02, 2, 0x00, 0x02, 0]               // bulk OUT, 512
    }

    public func Control(_ setup: Setup, _ data: [uint8]) -> Transfer {
        switch setup.Request {
        case 0xfe: return .data([0])                 // GET MAX LUN
        case 0xff: return .data([])                  // bulk-only reset
        default: return .stall
        }
    }

    public func In(endpoint: uint8, max: int) async -> Transfer {
        // TODO(P4): the data phase of the pending CBW, then its CSW
        // ("USBS", tag, residue, status).
        .nak
    }

    public func Out(endpoint: uint8, _ data: [uint8]) async -> Transfer {
        // A 31-byte CBW: "USBC", tag, data length, flags, LUN, CB length, CB.
        if data.count == 31 && LE.Uint32(data, from: 0) == 0x4342_5355 {
            pending = data
            return .data([])
        }
        // TODO(P4): WRITE data phase.
        return .data([])
    }

    /// READ CAPACITY(10) data: last LBA and block size, big-endian.
    func capacity10() -> [uint8] {
        var b = [uint8](repeating: 0, count: 8)
        let last = Image.Size / BlockSize - 1
        binary.BigEndian.PutUint32(&b, uint32(min(last, 0xffff_ffff)), at: 0)
        binary.BigEndian.PutUint32(&b, uint32(BlockSize), at: 4)
        return b
    }
}
