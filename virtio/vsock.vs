package virtio

import "encoding/binary"

/// virtio-vsock (spec §5.10): sockets between host and guest with no
/// network at all. The host is CID 2; the guest gets `Cid` (3 or more).
/// Guest agents and port forwarding use this instead of IP.
///
/// Queues: rx 0, tx 1, event 2. Every packet has a 44-byte header (src/dst
/// CID and port, len, type STREAM, op REQUEST/RESPONSE/RST/SHUTDOWN/RW/
/// CREDIT_UPDATE/CREDIT_REQUEST, buf_alloc, fwd_cnt).
public final class Vsock: Device {
    public let Id = DeviceId.vsock
    public let Cid: uint64
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil

    public init(cid: uint64 = 3) {
        Cid = cid
    }

    public var Features: uint64 { CommonFeatures }
    public var QueueSizes: [uint16] { [128, 128, 16] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 {
        var cfg = [uint8](repeating: 0, count: 8)
        binary.LittleEndian.PutUint64(&cfg, Cid, at: 0)
        return readLE(cfg, offset, size)
    }

    public func WriteConfig(offset: uint64, size: uint8, value: uint64) {}

    public func Activate(queues: [Queue], features: uint64, notify: any Notifier) throws {
        self.queues = queues
        self.notify = notify
    }

    public func Reset() {
        queues = []
        notify = nil
    }

    public func Notified(queue index: int) {
        // TODO(P3): the connection table, credit accounting, and a host side
        // API: Listen(port:) and Connect(port:) returning io.AsyncReader &
        // io.AsyncWriter streams.
    }
}
