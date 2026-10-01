package usb

import (
    "encoding/binary"
    "sync"
    "vm/disk"
)


/// USB mass storage, bulk-only transport (BOT), carrying SCSI. As a
/// CD-ROM (`.cdrom`) it is what a USB DVD drive is: 2048-byte blocks,
/// read-only, and the MMC commands Windows' cdrom.sys and UEFI ask an
/// optical drive. As a disk it is a removable direct-access device.
/// Prints each SCSI command and its outcome.
public var TraceScsi = false

public final class Storage: Peripheral {
    public enum Kind { case cdrom, disk }

    public let Image: any disk.Image
    public let Medium: Kind
    public let BlockSize: uint64
    public var OnData: (() -> Void)? = nil
    let lock = sync.Mutex()
    var phase = Phase.command
    var sense = Sense.none

    enum Phase {
        /// Waiting for a CBW.
        case command
        /// Bytes for the host, then the CSW.
        case dataIn(tag: uint32, expected: uint32, data: [uint8], sent: int, status: uint8)
        /// A READ: blocks still to send, read from the image as asked for.
        case readIn(tag: uint32, expected: uint32, offset: uint64, left: uint64, sent: uint64)
        /// Bytes from the host (a WRITE), then the CSW.
        case dataOut(tag: uint32, expected: uint32, offset: uint64, received: uint32, accept: bool)
        /// The CSW is next.
        case status(tag: uint32, residue: uint32, status: uint8)
    }

    struct Sense {
        var key: uint8
        var asc: uint8
        var ascq: uint8
        static let none = Sense(key: 0, asc: 0, ascq: 0)
        static let invalidOpcode = Sense(key: 5, asc: 0x20, ascq: 0)
        static let invalidField = Sense(key: 5, asc: 0x24, ascq: 0)
        static let outOfRange = Sense(key: 5, asc: 0x21, ascq: 0)
        static let writeProtected = Sense(key: 7, asc: 0x27, ascq: 0)
        static let readError = Sense(key: 3, asc: 0x11, ascq: 0)
    }

    public init(_ image: any disk.Image, kind: Kind = .cdrom) {
        Image = image
        Medium = kind
        BlockSize = kind == .cdrom ? 2048 : 512
    }

    public var Speed: uint8 { 3 }
    public var Product: string { Medium == .cdrom ? "Vertex Virtual CD-ROM" : "Vertex Virtual Disk" }
    public var DeviceDescriptor: [uint8] { deviceDescriptor(vendor: vendorId, product: 0x0003) }

    public var ConfigurationDescriptor: [uint8] {
        [9, 2, 32, 0, 1, 1, 0, 0x80, 50,
         9, 4, 0, 0, 2, 0x08, 0x06, 0x50, 0,         // mass storage, SCSI transparent, bulk-only
         7, 5, 0x81, 2, 0x00, 0x02, 0,               // bulk IN, 512
         7, 5, 0x02, 2, 0x00, 0x02, 0]               // bulk OUT, 512
    }

    var blocks: uint64 { Image.Size / BlockSize }
    var readOnly: bool { Medium == .cdrom || Image.ReadOnly }

    public func Control(_ setup: Setup, _ data: [uint8]) -> Transfer {
        if setup.Kind == 1 {
            switch setup.Request {
            case 0xfe: return .data([0])                 // GET MAX LUN: one LUN
            case 0xff:                                   // bulk-only mass storage reset
                lock.withLock { phase = .command }
                return .data([])
            default: return .stall
            }
        }
        return .data([])                                 // CLEAR_FEATURE(halt) and friends
    }

    public func Reset() {
        lock.withLock {
            phase = .command
            sense = .none
        }
    }

    // MARK: - Bulk OUT: commands and WRITE data

    public func Out(endpoint: uint8, _ data: [uint8]) async -> Transfer {
        let current = lock.withLock { phase }
        switch current {
        case .dataOut(let tag, let expected, let offset, let received, let accept):
            if accept && !data.isEmpty {
                do {
                    try await Image.WriteAt(offset + uint64(received), data)
                } catch {
                    lock.withLock {
                        sense = .readError
                        phase = .dataOut(tag: tag, expected: expected, offset: offset, received: received + uint32(data.count), accept: false)
                    }
                    return finishOut()
                }
            }
            lock.withLock {
                phase = .dataOut(tag: tag, expected: expected, offset: offset, received: received + uint32(data.count), accept: accept)
            }
            return finishOut()
        default:
            break
        }
        // A 31-byte CBW: "USBC", tag, data length, flags, LUN, CB length, CB.
        if data.count < 31 || binary.LittleEndian.Uint32(data, from: 0) != 0x4342_5355 {
            return .stall
        }
        let tag = binary.LittleEndian.Uint32(data, from: 4)
        let expected = binary.LittleEndian.Uint32(data, from: 8)
        let cdb = Array(data[15..<31])
        await execute(tag: tag, expected: expected, cdb: cdb)
        return .data([])
    }

    /// The WRITE data phase ends when all of it arrived.
    func finishOut() -> Transfer {
        lock.withLock {
            if case .dataOut(let tag, let expected, _, let received, let accept) = phase, received >= expected {
                phase = .status(tag: tag, residue: 0, status: accept ? 0 : 1)
            }
        }
        OnData?()
        return .data([])
    }

    // MARK: - Bulk IN: data, then the CSW

    public func In(endpoint: uint8, max: int) async -> Transfer {
        let current = lock.withLock { phase }
        switch current {
        case .command, .dataOut:
            return .nak
        case .status(let tag, let residue, let status):
            var csw = [uint8](repeating: 0, count: 13)
            binary.LittleEndian.PutUint32(&csw, 0x5342_5355, at: 0)       // "USBS"
            binary.LittleEndian.PutUint32(&csw, tag, at: 4)
            binary.LittleEndian.PutUint32(&csw, residue, at: 8)
            csw[12] = status
            lock.withLock { phase = .command }
            return .data(csw)
        case .dataIn(let tag, let expected, let data, let sent, let status):
            let n = min(max, data.count - sent)
            let out = Array(data[sent..<sent + n])
            lock.withLock {
                if sent + n >= data.count || n < max {
                    phase = .status(tag: tag, residue: expected - uint32(sent + n), status: status)
                } else {
                    phase = .dataIn(tag: tag, expected: expected, data: data, sent: sent + n, status: status)
                }
            }
            return .data(out)
        case .readIn(let tag, let expected, let offset, let left, let sent):
            let n = min(uint64(max), left)
            var buf = [uint8](repeating: 0, count: int(n))
            var ok = true
            if n > 0 {
                do {
                    try await Image.ReadAt(offset, into: &buf)
                } catch {
                    ok = false
                }
            }
            lock.withLock {
                if !ok {
                    sense = .readError
                    phase = .status(tag: tag, residue: expected - uint32(sent), status: 1)
                } else if left - n == 0 {
                    phase = .status(tag: tag, residue: expected - uint32(sent + n), status: 0)
                } else {
                    phase = .readIn(tag: tag, expected: expected, offset: offset + n, left: left - n, sent: sent + n)
                }
            }
            return ok ? .data(buf) : .data([])
        }
    }

    // MARK: - SCSI

    func execute(tag: uint32, expected: uint32, cdb: [uint8]) async {
        let op = cdb[0]
        if TraceScsi {
            var hex = ""
            for b in cdb.prefix(12) { hex += " \(string(b, radix: 16))" }
            print("[scsi] cdb\(hex) expect \(expected)")
        }
        var reply: [uint8]? = nil      // data for the host, cut to `expected`
        var fail: Sense? = nil
        switch op {
        case 0x00, 0x1b, 0x1e, 0x2b, 0x35, 0xbb, 0x91:
            // TEST UNIT READY, START STOP UNIT, PREVENT ALLOW MEDIUM REMOVAL,
            // SEEK, SYNCHRONIZE CACHE, SET CD SPEED: nothing to do.
            reply = [uint8]()
        case 0x03:
            reply = requestSense()
        case 0x12:
            (reply, fail) = inquiry(cdb)
        case 0x1a, 0x5a:
            (reply, fail) = modeSense(cdb)
        case 0x23:
            reply = readFormatCapacities()
        case 0x25:
            var b = [uint8](repeating: 0, count: 8)
            binary.BigEndian.PutUint32(&b, uint32(min(blocks - 1, 0xffff_ffff)), at: 0)
            binary.BigEndian.PutUint32(&b, uint32(BlockSize), at: 4)
            reply = b
        case 0x9e where cdb[1] & 0x1f == 0x10:
            var b = [uint8](repeating: 0, count: 32)
            binary.BigEndian.PutUint64(&b, blocks - 1, at: 0)
            binary.BigEndian.PutUint32(&b, uint32(BlockSize), at: 8)
            reply = b
        case 0x28, 0xa8, 0x88:
            let (lba, count) = lbaAndCount(cdb)
            if lba + count > blocks {
                fail = .outOfRange
            } else {
                let bytes = count * BlockSize
                lock.withLock {
                    sense = .none
                    if bytes == 0 {
                        phase = .status(tag: tag, residue: expected, status: 0)
                    } else {
                        phase = .readIn(tag: tag, expected: expected, offset: lba * BlockSize,
                                        left: min(bytes, uint64(expected)), sent: 0)
                    }
                }
                OnData?()
                return
            }
        case 0x2a, 0xaa, 0x8a:
            let (lba, count) = lbaAndCount(cdb)
            let accept = !readOnly && lba + count <= blocks
            lock.withLock {
                sense = accept ? .none : (readOnly ? .writeProtected : .outOfRange)
                if expected == 0 {
                    phase = .status(tag: tag, residue: 0, status: accept ? 0 : 1)
                } else {
                    phase = .dataOut(tag: tag, expected: expected, offset: lba * BlockSize, received: 0, accept: accept)
                }
            }
            OnData?()
            return
        case 0x43 where Medium == .cdrom:
            (reply, fail) = readToc(cdb)
        case 0x46 where Medium == .cdrom:
            reply = getConfiguration(cdb)
        case 0x4a where Medium == .cdrom:
            reply = eventStatus(cdb)
        case 0x51 where Medium == .cdrom:
            reply = discInformation()
        case 0x52 where Medium == .cdrom:
            reply = trackInformation()
        case 0xbd where Medium == .cdrom:
            reply = [uint8](repeating: 0, count: 8)       // MECHANISM STATUS: no changer
        default:
            fail = .invalidOpcode
        }
        if TraceScsi {
            if let f = fail {
                print("[scsi]   -> check condition key \(f.key) asc 0x\(string(f.asc, radix: 16))")
            } else {
                print("[scsi]   -> good, \((reply ?? []).count) bytes")
            }
        }
        lock.withLock {
            if let f = fail {
                sense = f
                // Any data the host expected is answered short: nothing.
                if expected > 0 && cdbIsIn(cdb) {
                    phase = .dataIn(tag: tag, expected: expected, data: [], sent: 0, status: 1)
                } else if expected > 0 {
                    phase = .dataOut(tag: tag, expected: expected, offset: 0, received: 0, accept: false)
                } else {
                    phase = .status(tag: tag, residue: 0, status: 1)
                }
                return
            }
            if op != 0x03 { sense = .none }
            let data = reply ?? []
            let cut = Array(data.prefix(int(expected)))
            if expected == 0 {
                phase = .status(tag: tag, residue: 0, status: 0)
            } else {
                phase = .dataIn(tag: tag, expected: expected, data: cut, sent: 0, status: 0)
            }
        }
        OnData?()
    }

    /// Whether a command the device refused had its data phase toward the
    /// host: everything but the writes.
    func cdbIsIn(_ cdb: [uint8]) -> bool {
        switch cdb[0] {
        case 0x2a, 0xaa, 0x8a, 0x55, 0x15: return false
        default: return true
        }
    }

    func lbaAndCount(_ cdb: [uint8]) -> (uint64, uint64) {
        switch cdb[0] {
        case 0x28, 0x2a:
            return (uint64(binary.BigEndian.Uint32(cdb, from: 2)), uint64(binary.BigEndian.Uint16(cdb, from: 7)))
        case 0xa8, 0xaa:
            return (uint64(binary.BigEndian.Uint32(cdb, from: 2)), uint64(binary.BigEndian.Uint32(cdb, from: 6)))
        default:
            return (binary.BigEndian.Uint64(cdb, from: 2), uint64(binary.BigEndian.Uint32(cdb, from: 10)))
        }
    }

    func requestSense() -> [uint8] {
        let s = lock.withLock { sense }
        var b = [uint8](repeating: 0, count: 18)
        b[0] = 0x70                       // current, fixed format
        b[2] = s.key
        b[7] = 10                         // additional length
        b[12] = s.asc
        b[13] = s.ascq
        lock.withLock { sense = .none }
        return b
    }

    var peripheralType: uint8 { Medium == .cdrom ? 0x05 : 0x00 }

    func inquiry(_ cdb: [uint8]) -> ([uint8]?, Sense?) {
        let length = int(binary.BigEndian.Uint16(cdb, from: 3))
        var out: [uint8]
        if cdb[1] & 1 != 0 {
            switch cdb[2] {
            case 0x00:
                out = [peripheralType, 0x00, 0, 3, 0x00, 0x80, 0x83]
            case 0x80:
                let serial = Array("VTX00000001".utf8)
                out = [peripheralType, 0x80, 0, uint8(serial.count)] + serial
            case 0x83:
                // One T10 vendor ID designator: "VERTEX  " and the product.
                let id = Array("VERTEX  ".utf8) + Array(Product.utf8)
                out = [peripheralType, 0x83, 0, uint8(id.count + 4), 0x02, 0x01, 0, uint8(id.count)] + id
            default:
                return (nil, .invalidField)
            }
        } else {
            out = [uint8](repeating: 0x20, count: 36)
            out[0] = peripheralType
            out[1] = 0x80                 // removable
            out[2] = 0x05                 // SPC-3
            out[3] = 0x02                 // response data format 2
            out[4] = 31                   // additional length
            out[5] = 0; out[6] = 0; out[7] = 0
            let vendor = Array("VERTEX".utf8)
            for i in 0..<vendor.count { out[8 + i] = vendor[i] }
            let product = Array((Medium == .cdrom ? "Virtual CD-ROM" : "Virtual Disk").utf8)
            for i in 0..<product.count { out[16 + i] = product[i] }
            let rev = Array("1.0".utf8)
            for i in 0..<rev.count { out[32 + i] = rev[i] }
        }
        return (Array(out.prefix(max(length, 0) == 0 ? out.count : length)), nil)
    }

    /// MODE SENSE (6) and (10): a header, and for a CD-ROM the
    /// capabilities page (0x2a) when asked for it or for all pages.
    func modeSense(_ cdb: [uint8]) -> ([uint8]?, Sense?) {
        let ten = cdb[0] == 0x5a
        let page = cdb[2] & 0x3f
        var pages: [uint8] = []
        if Medium == .cdrom && (page == 0x2a || page == 0x3f) {
            var p = [uint8](repeating: 0, count: 22)
            p[0] = 0x2a
            p[1] = 20
            p[2] = 0x09                   // reads CD-R and DVD-ROM
            p[4] = 0x71                   // audio play, mode 2 form 1/2, multi-session
            p[6] = 0x29                   // lock, eject, tray loading mechanism
            binary.BigEndian.PutUint16(&p, 2816, at: 8) // maximum read speed (16x), kB/s
            binary.BigEndian.PutUint16(&p, 2816, at: 14)
            pages = p
        } else if page != 0x3f && page != 0x08 && page != 0x1c && page != 0x01 && page != 0x00 {
            return (nil, .invalidField)
        }
        let wp: uint8 = readOnly ? 0x80 : 0
        var out: [uint8]
        if ten {
            out = [0, 0, 0, wp, 0, 0, 0, 0]
            binary.BigEndian.PutUint16(&out, uint16(6 + pages.count), at: 0)
        } else {
            out = [uint8(3 + pages.count), 0, wp, 0]
        }
        out.append(contentsOf: pages)
        return (out, nil)
    }

    func readFormatCapacities() -> [uint8] {
        var b = [uint8](repeating: 0, count: 12)
        b[3] = 8
        binary.BigEndian.PutUint32(&b, uint32(min(blocks, 0xffff_ffff)), at: 4)
        b[8] = 0x02                       // formatted media
        b[9] = uint8((BlockSize >> 16) & 0xff)
        b[10] = uint8((BlockSize >> 8) & 0xff)
        b[11] = uint8(BlockSize & 0xff)
        return b
    }

    /// READ TOC/PMA/ATIP, formats 0 (the TOC: one data track and the
    /// lead-out) and 1 (session information).
    func readToc(_ cdb: [uint8]) -> ([uint8]?, Sense?) {
        let msf = cdb[1] & 0x02 != 0
        var format = cdb[2] & 0x0f
        if format == 0 && cdb[9] >> 6 != 0 {
            format = cdb[9] >> 6          // the older place for it
        }
        func address(_ lba: uint64) -> [uint8] {
            if !msf {
                var b = [uint8](repeating: 0, count: 4)
                binary.BigEndian.PutUint32(&b, uint32(lba), at: 0)
                return b
            }
            let f = lba + 150
            return [0, uint8(f / (75 * 60)), uint8((f / 75) % 60), uint8(f % 75)]
        }
        var out: [uint8] = [0, 0, 1, 1]
        switch format {
        case 0:
            let track = cdb[6]
            if track > 1 && track != 0xaa { return (nil, .invalidField) }
            if track <= 1 {
                out += [0, 0x14, 1, 0] + address(0)
            }
            out += [0, 0x14, 0xaa, 0] + address(blocks)
        case 1:
            out += [0, 0x14, 1, 0] + address(0)
        default:
            return (nil, .invalidField)
        }
        binary.BigEndian.PutUint16(&out, uint16(out.count - 2), at: 0)
        return (out, nil)
    }

    /// GET CONFIGURATION: the DVD-ROM profile, and the profile-list and
    /// core features.
    func getConfiguration(_ cdb: [uint8]) -> [uint8] {
        var out = [uint8](repeating: 0, count: 8)
        binary.BigEndian.PutUint16(&out, 0x0010, at: 6)                       // current profile: DVD-ROM
        out += [0x00, 0x00, 0x03, 4, 0x00, 0x10, 0x01, 0x00]    // profile list: DVD-ROM, current
        out += [0x00, 0x01, 0x0b, 8, 0, 0, 0, 8, 0x01, 0, 0, 0] // core: USB interface, DBE
        out += [0x00, 0x03, 0x0b, 4, 0x29, 0, 0, 0]            // removable medium: tray, lock, eject
        binary.BigEndian.PutUint32(&out, uint32(out.count - 4), at: 0)
        return out
    }

    /// GET EVENT STATUS NOTIFICATION (polled): media present, no change.
    func eventStatus(_ cdb: [uint8]) -> [uint8] {
        if cdb[4] & 0x10 == 0 {
            return [0, 2, 0x80, 0x10]                           // no event class asked for that we have
        }
        return [0, 6, 0x04, 0x10, 0x00, 0x02, 0, 0]
    }

    func discInformation() -> [uint8] {
        var b = [uint8](repeating: 0, count: 34)
        binary.BigEndian.PutUint16(&b, 32, at: 0)
        b[2] = 0x0e                       // complete disc, last session complete
        b[3] = 1                          // first track
        b[4] = 1                          // sessions
        b[5] = 1                          // first track in last session
        b[6] = 1                          // last track in last session
        b[7] = 0x20                       // unrestricted use
        return b
    }

    func trackInformation() -> [uint8] {
        var b = [uint8](repeating: 0, count: 36)
        binary.BigEndian.PutUint16(&b, 34, at: 0)
        b[2] = 1                          // track 1
        b[3] = 1                          // session 1
        b[5] = 0x04                       // data track
        b[6] = 0x01                       // data mode 1
        binary.BigEndian.PutUint32(&b, 0, at: 8)        // start
        binary.BigEndian.PutUint32(&b, uint32(min(blocks, 0xffff_ffff)), at: 24)   // size
        return b
    }
}
