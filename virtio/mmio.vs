package virtio

import (
    "sync"
    "vm/device"
)

/// VirtIO over MMIO (spec §4.2), version 2: the micro platform's
/// transport. 0x200 bytes of registers; device config from 0x100.
///
/// With `legacy`, version 1 instead (spec §4.2.4), for kernels before
/// 4.0, which know no other: 32 feature bits and no VERSION_1, no
/// FEATURES_OK step, and each queue placed by one page number (QueuePFN)
/// in the legacy layout: descriptors, then the available ring, then the
/// used ring at the next QueueAlign boundary.
public final class MmioTransport: device.Mmio, Notifier {
    public static let Size: uint64 = 0x200

    let dev: any Device
    let memory: device.GuestMemory
    let irq: any device.Irq
    let lock = sync.Mutex()

    var queues: [Queue]
    var deviceFeaturesSel: uint32 = 0
    var driverFeaturesSel: uint32 = 0
    var driverFeatures: uint64 = 0
    var queueSel: uint32 = 0
    var status: uint8 = 0
    var interruptStatus: uint32 = 0
    var configGeneration: uint32 = 0
    public let Legacy: bool
    var guestPageSize: uint64 = 4096
    var queueAlign: [uint64]
    var queuePfn: [uint32]

    public init(_ dev: any Device, memory: device.GuestMemory, irq: any device.Irq, legacy: bool = false) {
        self.dev = dev
        Legacy = legacy
        queueAlign = [uint64](repeating: 4096, count: dev.QueueSizes.count)
        queuePfn = [uint32](repeating: 0, count: dev.QueueSizes.count)
        self.memory = memory
        self.irq = irq
        queues = dev.QueueSizes.enumerated().map { Queue(index: $0.offset, size: $0.element, memory: memory) }
    }

    var selected: Queue? {
        int(queueSel) < queues.count ? queues[int(queueSel)] : nil
    }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        return lock.withLock {
            if offset >= 0x100 {
                return dev.ReadConfig(offset: offset - 0x100, size: size)
            }
            switch offset {
            case 0x000: return 0x7472_6976                      // "virt"
            case 0x004: return Legacy ? 1 : 2                   // version 2: modern
            case 0x008: return uint64(dev.Id.rawValue)
            case 0x00c: return uint64(VendorId)
            case 0x010:
                if Legacy { return deviceFeaturesSel == 0 ? dev.Features & 0xffff_ffff : 0 }
                return deviceFeaturesSel == 0 ? dev.Features & 0xffff_ffff : dev.Features >> 32
            case 0x040: return Legacy ? uint64(int(queueSel) < queuePfn.count ? queuePfn[int(queueSel)] : 0) : 0
            case 0x034: return uint64(selected.map { dev.QueueSizes[$0.Index] } ?? 0)
            case 0x044: return (selected?.Ready ?? false) ? 1 : 0
            case 0x060: return uint64(interruptStatus)
            case 0x070: return uint64(status)
            case 0x0fc: return uint64(configGeneration)
            default: return 0
            }
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        var kicked: int? = nil
        lock.withLock {
            if offset >= 0x100 {
                dev.WriteConfig(offset: offset - 0x100, size: size, value: value)
                return
            }
            let v32 = uint32(truncatingIfNeeded: value)
            switch offset {
            case 0x014: deviceFeaturesSel = v32
            case 0x020:
                if driverFeaturesSel == 0 {
                    driverFeatures = (driverFeatures & 0xffff_ffff_0000_0000) | uint64(v32)
                } else if driverFeaturesSel == 1 {
                    driverFeatures = (driverFeatures & 0xffff_ffff) | (uint64(v32) << 32)
                }
            case 0x024: driverFeaturesSel = v32
            case 0x028: if Legacy && v32 != 0 { guestPageSize = uint64(v32) }
            case 0x030: queueSel = v32
            case 0x03c: if Legacy, int(queueSel) < queueAlign.count, v32 != 0 { queueAlign[int(queueSel)] = uint64(v32) }
            case 0x040: if Legacy { setPfn(v32) }
            case 0x038: if let q = selected { q.Size = uint16(truncatingIfNeeded: v32) }
            case 0x044: if let q = selected { q.Ready = v32 == 1 }
            case 0x050: kicked = int(v32)
            case 0x064:
                interruptStatus &= ~v32
                if interruptStatus == 0 { irq.Set(false) }
            case 0x070: writeStatus(uint8(truncatingIfNeeded: v32))
            case 0x080: setLow(&selected!.Descriptors, v32)
            case 0x084: setHigh(&selected!.Descriptors, v32)
            case 0x090: setLow(&selected!.Available, v32)
            case 0x094: setHigh(&selected!.Available, v32)
            case 0x0a0: setLow(&selected!.Used, v32)
            case 0x0a4: setHigh(&selected!.Used, v32)
            default: break
            }
        }
        // Outside the lock: the device starts a task and returns.
        if let q = kicked {
            dev.Notified(queue: q)
        }
    }

    /// Legacy: the selected queue lives at `pfn` pages; 0 takes it away.
    func setPfn(_ pfn: uint32) {
        guard let q = selected else { return }
        let i = q.Index
        queuePfn[i] = pfn
        if pfn == 0 {
            q.Ready = false
            return
        }
        let n = uint64(q.Size)
        let desc = uint64(pfn) * guestPageSize
        let avail = desc + 16 * n
        let align = queueAlign[i]
        // flags, idx, ring[n], used_event: 2 bytes each.
        let used = (avail + 6 + 2 * n + align - 1) / align * align
        q.Descriptors = device.GuestAddress(desc)
        q.Available = device.GuestAddress(avail)
        q.Used = device.GuestAddress(used)
        q.Ready = true
    }

    func writeStatus(_ s: uint8) {
        if s == 0 {
            status = 0
            driverFeatures = 0
            interruptStatus = 0
            for q in queues { q.Reset() }
            for i in 0..<queuePfn.count { queuePfn[i] = 0 }
            dev.Reset()
            return
        }
        if !Legacy && s & Status.featuresOk != 0 && status & Status.featuresOk == 0 {
            // Features the device never offered: refuse FEATURES_OK.
            if driverFeatures & ~dev.Features != 0 {
                status = s & ~Status.featuresOk
                return
            }
        }
        if s & Status.driverOk != 0 && status & Status.driverOk == 0 {
            for q in queues { q.EventIndex = driverFeatures & Feature.eventIdx != 0 }
            do {
                try dev.Activate(queues: queues, features: driverFeatures, notify: self)
            } catch {
                status = s | Status.needsReset
                return
            }
        }
        status = s
    }

    func setLow(_ a: inout device.GuestAddress, _ v: uint32) {
        a = device.GuestAddress((a.Value & 0xffff_ffff_0000_0000) | uint64(v))
    }

    func setHigh(_ a: inout device.GuestAddress, _ v: uint32) {
        a = device.GuestAddress((a.Value & 0xffff_ffff) | (uint64(v) << 32))
    }

    public func QueueUsed(_ index: int) {
        lock.withLock { interruptStatus = interruptStatus | 1 }
        irq.Set(true)
    }

    public func ConfigChanged() {
        lock.withLock {
            interruptStatus = interruptStatus | 2
            configGeneration = configGeneration &+ 1
        }
        irq.Set(true)
    }
}
