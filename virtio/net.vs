package virtio

import "net/ether"

/// virtio-net (spec §5.1): an Ethernet port for the guest. The other end
/// is an `ether.Port`: `net/nat` (unprivileged NAT, the default) or
/// `net/tap` (a bridge on the host).
public final class Net: Device {
    public let Id = DeviceId.net
    public let Mac: ether.Mac
    let port: any ether.Port
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil

    static let featureMac: uint64 = 1 << 5
    static let featureStatus: uint64 = 1 << 16
    static let featureMrgRxbuf: uint64 = 1 << 15

    /// The 12-byte virtio_net_hdr in front of every frame (VERSION_1 with
    /// no offloads: all zeroes but num_buffers).
    static let headerSize = 12

    public init(port: any ether.Port, mac: ether.Mac = ether.Mac.Random()) {
        self.port = port
        Mac = mac
    }

    public var Features: uint64 {
        CommonFeatures | Net.featureMac | Net.featureStatus | Net.featureMrgRxbuf
    }

    /// Receive queue 0, transmit queue 1.
    public var QueueSizes: [uint16] { [256, 256] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 {
        var cfg = Mac.Bytes + [0, 0]
        cfg[6] = 1   // status: VIRTIO_NET_S_LINK_UP
        return readLE(cfg, offset, size)
    }

    public func WriteConfig(offset: uint64, size: uint8, value: uint64) {}

    public func Activate(queues: [Queue], features: uint64, notify: any Notifier) throws {
        self.queues = queues
        self.notify = notify
        let rx = queues[0]
        Task {
            // Frames from the host, into buffers the guest posted on rx.
            while let frame = try? await self.port.Receive() {
                guard let chain = try? rx.Pop() else {
                    continue   // no buffers posted: drop, as a NIC would
                }
                var packet = [uint8](repeating: 0, count: Net.headerSize)
                packet[10] = 1   // num_buffers
                packet.append(contentsOf: frame)
                if let n = try? rx.WriteAll(chain, packet), (try? rx.Push(chain.Head, written: n)) == true {
                    self.notify?.QueueUsed(0)
                }
            }
        }
    }

    public func Reset() {
        queues = []
        notify = nil
    }

    public func Notified(queue index: int) {
        if index != 1 { return }
        let tx = queues[1]
        Task {
            while let chain = try? tx.Pop() {
                if let bytes = try? tx.ReadAll(chain), bytes.count > Net.headerSize {
                    try? await self.port.Send(Array(bytes[Net.headerSize...]))
                }
                if (try? tx.Push(chain.Head, written: 0)) == true {
                    self.notify?.QueueUsed(1)
                }
            }
        }
    }
}
