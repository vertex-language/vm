package virtio

import "crypto/rand"

/// virtio-rng (spec §5.4): entropy from the host's generator.
public final class Rng: Device {
    public let Id = DeviceId.entropy
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil

    public init() {}

    public var Features: uint64 { CommonFeatures }
    public var QueueSizes: [uint16] { [64] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 { 0 }
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
        let q = queues[0]
        while let chain = try? q.Pop() {
            guard let bytes = try? rand.Bytes(int(min(chain.WritableCount, 4096))) else { return }
            if let n = try? q.WriteAll(chain, bytes), (try? q.Push(chain.Head, written: n)) == true {
                notify?.QueueUsed(0)
            }
        }
    }
}
