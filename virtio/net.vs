package virtio

import (
    "net/ether"
    "sync"
)

/// virtio-net (spec §5.1): an Ethernet port for the guest. The other end
/// is an `ether.Port`: `net/nat` (unprivileged NAT, the default) or
/// `net/tap` (a bridge on the host).
public final class Net: Device {
    public let Id = DeviceId.net
    public let Mac: ether.Mac
    let port: any ether.Port
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil
    let txLock = sync.Mutex()

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
                var chain: Chain? = nil
                for _ in 0..<100 {
                    if let c = try? rx.Pop() {
                        chain = c
                        break
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                guard let c = chain else {
                    continue
                }

                var packet = [uint8](repeating: 0, count: Net.headerSize)
                packet[10] = 1   // num_buffers
                packet.append(contentsOf: frame)
                if let n = try? rx.WriteAll(c, packet) {
                    let needIntr = (try? rx.Push(c.Head, written: n)) ?? true
                    if needIntr {
                        self.notify?.QueueUsed(0)
                    }
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
        Task {
            await self.processTx()
        }
    }

    func processTx() async {
        guard queues.count > 1 else { return }
        let tx = queues[1]
        while true {
            var item: Chain? = nil
            do {
                try txLock.withLock {
                    item = try tx.Pop()
                }
            } catch {
                item = nil
            }
            guard let chain = item else { break }

            if let bytes = try? tx.ReadAll(chain), bytes.count > Net.headerSize {
                let frame = Array(bytes[Net.headerSize...])
                try? await self.port.Send(frame)
            }
            var needIntr = true
            txLock.withLock {
                needIntr = (try? tx.Push(chain.Head, written: 0)) ?? true
            }
            if needIntr {
                self.notify?.QueueUsed(1)
            }
        }
    }
}
