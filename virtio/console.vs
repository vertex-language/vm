package virtio

import "io"

/// virtio-console (spec §5.3): the guest's hvc0, joined to a host stream.
/// One port, no multiport: receive queue 0, transmit queue 1.
public final class Console: Device {
    public let Id = DeviceId(rawValue: 3)
    let input: (any io.AsyncReader)?
    let output: any io.AsyncWriter
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil

    /// `input` is what the guest reads (nil for none); `output` is where
    /// what it writes goes.
    public init(input: (any io.AsyncReader)?, output: any io.AsyncWriter) {
        self.input = input
        self.output = output
    }

    public var Features: uint64 { CommonFeatures }
    public var QueueSizes: [uint16] { [64, 64] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 { 0 }
    public func WriteConfig(offset: uint64, size: uint8, value: uint64) {}

    public func Activate(queues: [Queue], features: uint64, notify: any Notifier) throws {
        self.queues = queues
        self.notify = notify
        guard let input = input else { return }
        let rx = queues[0]
        Task {
            var buf = [uint8](repeating: 0, count: 256)
            while let n = try? await input.Read(into: &buf), n > 0 {
                guard let chain = try? rx.Pop() else { continue }
                if let w = try? rx.WriteAll(chain, Array(buf[0..<n])), (try? rx.Push(chain.Head, written: w)) == true {
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
                if let bytes = try? tx.ReadAll(chain) {
                    try? await self.output.Write(bytes)
                }
                if (try? tx.Push(chain.Head, written: 0)) == true {
                    self.notify?.QueueUsed(1)
                }
            }
        }
    }
}
