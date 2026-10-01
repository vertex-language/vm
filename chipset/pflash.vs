package chipset

import (
    "encoding/binary"
    "sync"
    "vm/device"
)

/// PflashCfi01 emulates a parallel NOR flash memory device conforming to the
/// Common Flash Interface (CFI) and Intel StrataFlash (P30) command set.
///
/// In UEFI virtual machines (like ArmVirtQemu), this device acts as Flash 1
/// (UEFI Non-Volatile Variable Storage). It handles status register polling,
/// block erasure, and word/buffer programming so EDK2's VirtNorFlashDxe
/// can initialize the variable store and produce the Variable Arch Protocol.
public final class PflashCfi01: device.Mmio {
    public enum Mode {
        case readArray
        case readStatus
        case readIdentifier
        case readCfi
    }

    enum State {
        case idle
        case eraseSetup
        case programSetup
        case bufferSetup
        case bufferWriting
        case bufferConfirm
    }

    public static let BlockSize: int = 256 * 1024 // 256 KiB blocks

    let lock = sync.Mutex()
    var data: [uint8]
    var mode: Mode = .readArray
    var state: State = .idle
    var statusReg: uint8 = 0x80 // Bit 7 = Ready (WSMS)
    var bufferCount: int = 0

    public init(size: int = 64 * 1024 * 1024, initialData: [uint8]? = nil) {
        if let initBytes = initialData, initBytes.count > 0 {
            var buf = [uint8](repeating: 0xff, count: size)
            let toCopy = min(initBytes.count, size)
            for i in 0..<toCopy {
                buf[i] = initBytes[i]
            }
            self.data = buf
        } else {
            self.data = [uint8](repeating: 0xff, count: size)
        }
    }

    /// Returns a copy of the current flash contents (e.g. for saving NVRAM variables to disk).
    public var Bytes: [uint8] {
        lock.withLock { data }
    }

    public func Read(offset o: uint64, size: uint8) -> uint64 {
        return lock.withLock {
            switch mode {
            case .readStatus:
                // Return 0x80 (Ready) in byte 0 of every 16-bit word
                var ret: uint64 = 0
                for i in 0..<int(size) {
                    if (i & 1) == 0 {
                        ret |= (uint64(statusReg) << (8 * uint64(i)))
                    }
                }
                return ret

            case .readIdentifier:
                let off16 = (o & 0xff) >> 1
                switch off16 {
                case 0x00: return 0x0089 // Intel manufacturer ID
                case 0x01: return 0x8891 // Device ID (P30 64MB)
                case 0x02: return 0x0000 // Block lock status: unlocked (bit 0 = 0)
                default: return 0
                }

            case .readCfi:
                // CFI Query table (starts at word offset 0x10 / byte offset 0x20)
                let wordOff = (o & 0xff) >> 1
                switch wordOff {
                case 0x10: return 0x51 // 'Q'
                case 0x11: return 0x52 // 'R'
                case 0x12: return 0x59 // 'Y'
                case 0x13: return 0x01 // Primary algorithm (Intel/Sharp extended)
                case 0x14: return 0x00
                case 0x27: return 26   // Device size: 2^26 = 64 MiB
                case 0x28: return 0x01 // Interface: x16
                case 0x29: return 0x00
                case 0x2a: return 0x06 // Max bytes in write buffer = 2^6 = 64 bytes
                case 0x2b: return 0x00
                case 0x2c: return 0x01 // 1 erase block region
                case 0x2d: return 0xff // 256 blocks - 1 = 255 (0x00ff)
                case 0x2e: return 0x00
                case 0x2f: return 0x00 // 256 KiB per block (256 * 256 = 65536 * 4 bytes)
                case 0x30: return 0x04
                default: return 0
                }

            case .readArray:
                var v: uint64 = 0
                for i in 0..<int(size) {
                    let at = int(o) + i
                    if at < data.count {
                        v |= uint64(data[at]) << (8 * uint64(i))
                    }
                }
                return v
            }
        }
    }

    public func Write(offset o: uint64, size: uint8, value: uint64) {
        lock.withLock {
            let cmd = uint8(value & 0xff)

            switch state {
            case .eraseSetup:
                if cmd == 0xd0 { // Erase confirm
                    let blockStart = (int(o) / PflashCfi01.BlockSize) * PflashCfi01.BlockSize
                    let blockEnd = min(blockStart + PflashCfi01.BlockSize, data.count)
                    for b in blockStart..<blockEnd {
                        data[b] = 0xff
                    }
                }
                mode = .readStatus
                state = .idle

            case .programSetup:
                var v = value
                for i in 0..<int(size) {
                    let at = int(o) + i
                    if at < data.count {
                        data[at] &= uint8(v & 0xff)
                    }
                    v >>= 8
                }
                mode = .readStatus
                state = .idle

            case .bufferSetup:
                bufferCount = int(value & 0xff) + 1
                state = .bufferWriting
                mode = .readStatus

            case .bufferWriting:
                var v = value
                for i in 0..<int(size) {
                    let at = int(o) + i
                    if at < data.count {
                        data[at] &= uint8(v & 0xff)
                    }
                    v >>= 8
                }
                bufferCount -= 1
                if bufferCount <= 0 {
                    state = .bufferConfirm
                }

            case .bufferConfirm:
                mode = .readStatus
                state = .idle

            case .idle:
                switch cmd {
                case 0x00, 0xff:
                    mode = .readArray
                case 0x70:
                    mode = .readStatus
                case 0x50:
                    statusReg = 0x80
                    mode = .readStatus
                case 0x90:
                    mode = .readIdentifier
                case 0x98:
                    mode = .readCfi
                case 0x20:
                    state = .eraseSetup
                    mode = .readStatus
                case 0x40, 0x10:
                    state = .programSetup
                    mode = .readStatus
                case 0xe8:
                    state = .bufferSetup
                    mode = .readStatus
                case 0x60: // Block lock setup (0x01 lock, 0xd0 unlock)
                    mode = .readStatus
                default:
                    mode = .readArray
                }
            }
        }
    }
}
