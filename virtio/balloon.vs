package virtio

import "encoding/binary"

/// virtio-balloon (spec §5.5): the guest gives pages back to the host on
/// request, and reports free pages. Queues: inflate 0, deflate 1, stats 2.
public final class Balloon: Device {
    public let Id = DeviceId(rawValue: 5)
    /// How many 4 KiB pages the host wants the guest to give up.
    public var TargetPages: uint32 = 0
    var actualPages: uint32 = 0
    var queues: [Queue] = []
    var notify: (any Notifier)? = nil

    public init() {}

    public var Features: uint64 { CommonFeatures | (1 << 1) }   // STATS_VQ
    public var QueueSizes: [uint16] { [128, 128, 16] }

    public func ReadConfig(offset: uint64, size: uint8) -> uint64 {
        var cfg = [uint8](repeating: 0, count: 8)
        binary.LittleEndian.PutUint32(&cfg, TargetPages, at: 0)
        binary.LittleEndian.PutUint32(&cfg, actualPages, at: 4)
        return readLE(cfg, offset, size)
    }

    public func WriteConfig(offset: uint64, size: uint8, value: uint64) {
        if offset == 4 && size == 4 {
            actualPages = uint32(truncatingIfNeeded: value)
        }
    }

    public func Activate(queues: [Queue], features: uint64, notify: any Notifier) throws {
        self.queues = queues
        self.notify = notify
    }

    public func Reset() {
        queues = []
        notify = nil
    }

    /// Asks the guest to hold `pages` pages.
    public func SetTarget(_ pages: uint32) {
        TargetPages = pages
        notify?.ConfigChanged()
    }

    public func Notified(queue index: int) {
        // TODO(P6): inflate → madvise(DONTNEED) / DiscardVirtualMemory the
        // page frame numbers listed; deflate → nothing to do; stats → keep.
    }
}
