package virtio

import "encoding/binary"

/// virtio-input (spec §5.8): evdev events, for Linux guests with a
/// display. Windows has no inbox driver, so Windows gets usb.Keyboard and
/// usb.Tablet instead. Queues: event 0, status 1.
public final class Input: Device {
    public enum Kind { case keyboard, tablet }

    public let Id = DeviceId.input
    public let DeviceKind: Kind
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil

    public init(_ kind: Kind) {
        DeviceKind = kind
    }

    public var Features: uint64 { CommonFeatures }
    public var QueueSizes: [uint16] { [64, 64] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 {
        // TODO(P6): select/subsel → name, serial, ev_bits (EV_KEY, EV_ABS), abs_info.
        0
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

    public func Notified(queue index: int) {}

    /// Queues one evdev event (type, code, value) for the guest.
    public func Send(type: uint16, code: uint16, value: uint32) {
        guard !queues.isEmpty, let chain = try? queues[0].Pop() else { return }
        var ev = [uint8](repeating: 0, count: 8)
        binary.LittleEndian.PutUint16(&ev, type, at: 0)
        binary.LittleEndian.PutUint16(&ev, code, at: 2)
        binary.LittleEndian.PutUint32(&ev, value, at: 4)
        if let n = try? queues[0].WriteAll(chain, ev), (try? queues[0].Push(chain.Head, written: n)) == true {
            notify?.QueueUsed(0)
        }
    }
}
