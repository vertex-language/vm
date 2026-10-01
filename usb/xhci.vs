package usb

import (
    "encoding/binary"
    "sync"
    "time"
    "vm/device"
    "vm/pci"
)

/// An xHCI host controller (xHCI 1.0) on PCI, with a USB 2.0 root hub:
/// capability, operational, runtime and doorbell registers in BAR 0, a
/// command ring, one interrupter with its event ring, and a device
/// context per slot. Interrupts are MSI-X where the platform delivers MSIs,
/// and PCI INTx otherwise.
///
/// Commands run on the vCPU thread that rings doorbell 0. Each endpoint's
/// transfer ring runs in a task of its own, one at a time; an interrupt or
/// bulk IN endpoint with nothing to say keeps its TD until its device calls
/// OnData.
public final class Xhci: pci.Function {
    public let Config: pci.ConfigSpace
    let memory: device.GuestMemory
    let lock = sync.Mutex()
    let ports: [Port]
    var slots: [Slot?]
    let started = time.Instant.Now()

    // BAR 0 layout.
    static let capLength: uint64 = 0x40
    static let opBase: uint64 = 0x40
    static let portBase: uint64 = 0x440
    static let runtimeBase: uint64 = 0x1000
    static let doorbellBase: uint64 = 0x2000
    static let extCapBase: uint64 = 0x3000
    static let maxSlots = 32
    /// Prints every TD and event: for finding out why a guest's driver
    /// waits forever.
    public var Trace = false

    // Operational registers.
    var usbcmd: uint32 = 0
    var usbsts: uint32 = 1           // HCHalted
    var dnctrl: uint32 = 0
    var crcr: uint64 = 0
    var commandRing: uint64 = 0
    var commandCycle = true
    var commandRunning = false
    var dcbaap: uint64 = 0
    var config: uint32 = 0

    // Interrupter 0.
    var iman: uint32 = 0
    var imod: uint32 = 0x0000_0fa0
    var erstsz: uint32 = 0
    var erstba: uint64 = 0
    var erdp: uint64 = 0
    var eventSegment = 0
    var eventIndex: uint64 = 0
    var eventCycle = true
    var segmentBase: uint64 = 0
    var segmentSize: uint64 = 0
    var waitingEvents: [[uint8]] = []
    var lastLevel = false

    /// MSI-X, where the platform can deliver MSIs: one vector, interrupter 0.
    let msix: pci.MsixTable?
    static let msixTable: uint64 = 0x8000
    static let msixPba: uint64 = 0x9000

    /// `msi` delivers MSI-X writes; nil leaves the controller on INTx.
    public init(memory: device.GuestMemory, msi: (any device.Msi)? = nil, ports: int = 4) {
        self.memory = memory
        var p: [Port] = []
        for i in 0..<ports { p.append(Port(number: i + 1)) }
        self.ports = p
        slots = [Slot?](repeating: nil, count: Xhci.maxSlots + 1)
        Config = pci.ConfigSpace(vendor: 0x1b36, device: 0x000d, classCode: .xhci, revision: 1)
        Config.Bytes[0x60] = 0x30        // SBRN: USB 3.0 controller
        Config.Bytes[0x61] = 0x20        // FLADJ
        Config.SetWritable(0x61, 1, mask: 0x3f)
        Config.ReserveCapabilities(upTo: 0x70)
        Config.AddPcieCapability()
        if let m = msi {
            let table = pci.MsixTable(vectors: 1, msi: m)
            Config.AddMsixCapability(table, bar: 0, tableOffset: uint32(Xhci.msixTable), pbaOffset: uint32(Xhci.msixPba))
            msix = table
        } else {
            msix = nil
        }
    }

    /// Plugs a device into the first free port; returns the port number (1-based).
    @discardableResult
    public func Plug(_ d: any Peripheral) -> int? {
        let n = lock.withLock { () -> int? in
            guard let p = ports.first(where: { $0.device == nil }) else { return nil }
            p.device = d
            p.connect()
            return p.Number
        }
        d.OnData = { [self] in self.wake(d) }
        return n
    }

    public var Bars: [pci.Bar] {
        [pci.Bar(index: 0, size: 0x10000, kind: .memory64, prefetchable: false)]
    }

    // MARK: - Registers

    public func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64 {
        if let t = msix, offset >= Xhci.msixTable {
            return offset < Xhci.msixPba ? t.ReadTable(offset: offset - Xhci.msixTable, size: size)
                                         : t.ReadPba(offset: offset - Xhci.msixPba, size: size)
        }
        let v = lock.withLock { readRegister(offset & ~3) }
        // Narrow and unaligned reads: the bytes of the dword they fall in.
        if size < 4 {
            let shift = 8 * (offset & 3)
            return (v >> shift) & ((uint64(1) << (8 * uint64(size))) - 1)
        }
        if size == 8 {
            let hi = lock.withLock { readRegister((offset & ~3) + 4) }
            return (v & 0xffff_ffff) | (hi << 32)
        }
        return v & 0xffff_ffff
    }

    func readRegister(_ offset: uint64) -> uint64 {
        switch offset {
        case 0x00: return Xhci.capLength | (0x0100 << 16)                              // CAPLENGTH, HCIVERSION 1.0
        case 0x04: return uint64(Xhci.maxSlots) | (1 << 8) | (uint64(ports.count) << 24) // HCSPARAMS1
        case 0x08: return 0x0000_0040                                                   // HCSPARAMS2: ERST max 2^4
        case 0x0c: return 0                                                             // HCSPARAMS3
        case 0x10: return 0x0000_0001 | ((Xhci.extCapBase >> 2) << 16)                  // HCCPARAMS1: AC64, xECP
        case 0x14: return Xhci.doorbellBase
        case 0x18: return Xhci.runtimeBase
        case 0x1c: return 0
        case Xhci.opBase + 0x00: return uint64(usbcmd)
        case Xhci.opBase + 0x04: return uint64(usbsts)
        case Xhci.opBase + 0x08: return 1                                               // PAGESIZE: 4 KiB
        case Xhci.opBase + 0x14: return uint64(dnctrl)
        case Xhci.opBase + 0x18: return commandRunning ? 8 : 0                          // CRCR: CRR only
        case Xhci.opBase + 0x1c: return 0
        case Xhci.opBase + 0x30: return dcbaap & 0xffff_ffff
        case Xhci.opBase + 0x34: return dcbaap >> 32
        case Xhci.opBase + 0x38: return uint64(config)
        case Xhci.runtimeBase:
            // MFINDEX: 125 µs microframes since the controller started.
            let us = (time.Instant.Now() - started).AsMicroseconds()
            return uint64(us / 125) & 0x3fff
        case Xhci.runtimeBase + 0x20: return uint64(iman)
        case Xhci.runtimeBase + 0x24: return uint64(imod)
        case Xhci.runtimeBase + 0x28: return uint64(erstsz)
        case Xhci.runtimeBase + 0x30: return erstba & 0xffff_ffff
        case Xhci.runtimeBase + 0x34: return erstba >> 32
        case Xhci.runtimeBase + 0x38: return erdp & 0xffff_ffff
        case Xhci.runtimeBase + 0x3c: return erdp >> 32
        // Supported Protocol capability: USB 2.0 on every port.
        case Xhci.extCapBase + 0x0: return 0x0200_0002
        case Xhci.extCapBase + 0x4: return 0x2042_5355                                  // "USB "
        case Xhci.extCapBase + 0x8: return 1 | (uint64(ports.count) << 8)
        case Xhci.extCapBase + 0xc: return 0
        default:
            if offset >= Xhci.portBase && offset < Xhci.portBase + 0x10 * uint64(ports.count) {
                let p = ports[int((offset - Xhci.portBase) / 0x10)]
                return (offset - Xhci.portBase) % 0x10 == 0 ? uint64(p.portsc()) : 0
            }
            return 0
        }
    }

    public func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64) {
        if size == 8 && offset < Xhci.msixTable {
            WriteBar(bar, offset: offset, size: 4, value: value & 0xffff_ffff)
            WriteBar(bar, offset: offset + 4, size: 4, value: value >> 32)
            return
        }
        if offset >= Xhci.msixTable {
            if let t = msix, offset < Xhci.msixPba {
                t.WriteTable(offset: offset - Xhci.msixTable, size: size, value: value)
            }
            return
        }
        let v = uint32(truncatingIfNeeded: value)
        if Trace && offset < Xhci.doorbellBase { print("[xhci] write 0x\(string(offset, radix: 16)) = 0x\(string(v, radix: 16))") }
        if offset >= Xhci.doorbellBase && offset < Xhci.doorbellBase + 4 * uint64(Xhci.maxSlots + 1) {
            ring(int((offset - Xhci.doorbellBase) / 4), v)
            return
        }
        lock.withLock { writeRegister(offset, v) }
        updateIntx()
    }

    func writeRegister(_ offset: uint64, _ v: uint32) {
        switch offset {
        case Xhci.opBase + 0x00:
            if v & 2 != 0 {
                reset()
                return
            }
            usbcmd = v & 0x0000_2f0d
            if v & 1 != 0 { usbsts &= ~1 } else { usbsts |= 1 }
            deliverMsi()
        case Xhci.opBase + 0x04:
            usbsts &= ~(v & 0x0000_041c)                                                   // RW1C: HSE, EINT, PCD, SRE
        case Xhci.opBase + 0x14:
            dnctrl = v
        case Xhci.opBase + 0x18:
            if v & 0x4 != 0 && commandRunning {
                // Command Abort: stop the ring and say so.
                commandRunning = false
                postCommandCompletion(at: commandRing, code: 24, slot: 0)
            }
            if !commandRunning {
                commandRing = (commandRing & 0xffff_ffff_0000_0000) | uint64(v & ~0x3f)
                commandCycle = v & 1 != 0
            }
        case Xhci.opBase + 0x1c:
            if !commandRunning {
                commandRing = (commandRing & 0xffff_ffff) | (uint64(v) << 32)
            }
        case Xhci.opBase + 0x30: dcbaap = (dcbaap & 0xffff_ffff_0000_0000) | uint64(v & ~0x3f)
        case Xhci.opBase + 0x34: dcbaap = (dcbaap & 0xffff_ffff) | (uint64(v) << 32)
        case Xhci.opBase + 0x38: config = v & 0xff
        case Xhci.runtimeBase + 0x20:
            iman = (iman & ~(v & 1)) & ~2 | (v & 2)                                         // IP is RW1C, IE RW
            deliverMsi()
        case Xhci.runtimeBase + 0x24: imod = v
        case Xhci.runtimeBase + 0x28: erstsz = v & 0xffff
        case Xhci.runtimeBase + 0x30:
            erstba = (erstba & 0xffff_ffff_0000_0000) | uint64(v & ~0x3f)
            resetEventRing()
        case Xhci.runtimeBase + 0x34:
            erstba = (erstba & 0xffff_ffff) | (uint64(v) << 32)
            resetEventRing()
        case Xhci.runtimeBase + 0x38:
            let ehb = erdp & 0x8
            let cleared = v & 0x8 != 0
            erdp = (erdp & 0xffff_ffff_0000_0000) | uint64(v & ~0xf) | (cleared ? 0 : ehb)
            dequeueMoved()
        case Xhci.runtimeBase + 0x3c:
            erdp = (erdp & 0xffff_ffff) | (uint64(v) << 32)
            dequeueMoved()
        default:
            if offset >= Xhci.portBase && offset < Xhci.portBase + 0x10 * uint64(ports.count) && (offset - Xhci.portBase) % 0x10 == 0 {
                writePortsc(ports[int((offset - Xhci.portBase) / 0x10)], v)
            }
        }
    }

    /// HCRST: every slot, ring and port back to power-on.
    func reset() {
        usbcmd = 0
        usbsts = 1
        dnctrl = 0
        crcr = 0
        commandRing = 0
        commandCycle = true
        commandRunning = false
        dcbaap = 0
        config = 0
        iman = 0
        imod = 0x0000_0fa0
        erstsz = 0
        erstba = 0
        erdp = 0
        eventSegment = 0
        eventIndex = 0
        eventCycle = true
        segmentBase = 0
        segmentSize = 0
        waitingEvents.removeAll()
        for i in 0..<slots.count { slots[i] = nil }
        for p in ports { p.connect() }
    }

    /// The INTx level: interrupter 0 has an interrupt pending and enabled,
    /// and so does the controller.
    ///
    /// Driven under the lock, so a level worked out on one thread can't be
    /// set after a newer one from another (see nvme.Controller).
    func updateIntx() {
        lock.withLock {
            let level = iman & 3 == 3 && usbcmd & 4 != 0
            if Trace && level != lastLevel { print("[xhci] INTx \(level)") }
            lastLevel = level
            Config.SetIntx(level)
        }
    }

    // MARK: - Ports

    func writePortsc(_ p: Port, _ v: uint32) {
        // RW1C change bits.
        p.changes &= ~(v & 0x00fe_0000)
        p.wake = v & 0x0e00_0000
        if v & 0x2 != 0 {
            p.enabled = false                                                              // PED: write 1 to disable
        }
        if v & 0x10 != 0 {
            // Port reset (USB 2): the device is reset and the port enabled.
            if let d = p.device {
                d.Reset()
                p.enabled = true
                p.linkState = 0
            }
            p.changes |= 1 << 21                                                           // PRC
            postPortChange(p)
        }
        if v & (1 << 16) != 0 {
            // Link state write (LWS): suspend (3), or resume (15) to U0.
            let pls = (v >> 5) & 0xf
            if pls == 3 {
                p.linkState = 3
            } else if pls == 15 || pls == 0 {
                if p.linkState == 3 {
                    p.linkState = 0
                    p.changes |= 1 << 22                                                   // PLC
                    postPortChange(p)
                }
            }
        }
    }

    func postPortChange(_ p: Port) {
        usbsts |= 0x10                                                                    // PCD
        var trb = [uint8](repeating: 0, count: 16)
        binary.LittleEndian.PutUint32(&trb, uint32(p.Number) << 24, at: 0)
        binary.LittleEndian.PutUint32(&trb, 1 << 24, at: 8)
        binary.LittleEndian.PutUint32(&trb, 34 << 10, at: 12)
        postEvent(trb)
    }

    // MARK: - The event ring

    func resetEventRing() {
        eventSegment = 0
        eventIndex = 0
        eventCycle = true
        loadSegment()
    }

    func loadSegment() {
        segmentBase = 0
        segmentSize = 0
        if erstba == 0 || erstsz == 0 { return }
        let entry = device.GuestAddress(erstba + uint64(eventSegment) * 16)
        segmentBase = ((try? memory.Load64(entry)) ?? 0) & ~0x3f
        segmentSize = uint64(((try? memory.Load32(entry.Adding(8))) ?? 0) & 0xffff)
    }

    var enqueueAddress: uint64 { segmentBase + eventIndex * 16 }

    /// Writes an event TRB (its cycle bit is set here) and raises the
    /// interrupter. An event that would fill the ring waits for the guest
    /// to move its dequeue pointer.
    func postEvent(_ trb: [uint8]) {
        if segmentBase == 0 || segmentSize == 0 { return }
        if !waitingEvents.isEmpty || ringFull() {
            waitingEvents.append(trb)
            return
        }
        writeEvent(trb)
    }

    func ringFull() -> bool {
        // The slot after the enqueue pointer is the dequeue pointer.
        var seg = eventSegment
        var idx = eventIndex + 1
        var base = segmentBase
        if idx >= segmentSize {
            seg = (seg + 1) % int(max(erstsz, 1))
            idx = 0
            let entry = device.GuestAddress(erstba + uint64(seg) * 16)
            base = ((try? memory.Load64(entry)) ?? 0) & ~0x3f
        }
        return base + idx * 16 == erdp & ~0xf
    }

    func writeEvent(_ trb: [uint8]) {
        var t = trb
        if eventCycle { t[12] |= 1 } else { t[12] &= ~1 }
        // The guest polls the cycle bit with no lock of ours, so the rest
        // of the TRB -- and the data it reports -- must be visible first.
        let at = device.GuestAddress(enqueueAddress)
        try? memory.Write(at, Array(t[0..<12]))
        sync.MemoryFence()
        try? memory.Write(at.Adding(12), Array(t[12..<16]))
        eventIndex += 1
        if eventIndex >= segmentSize {
            eventIndex = 0
            eventSegment += 1
            if eventSegment >= int(erstsz) {
                eventSegment = 0
                eventCycle = !eventCycle
            }
            loadSegment()
        }
        raise()
    }

    /// An event is waiting: interrupter 0 has an interrupt pending.
    ///
    /// INTx: IP and EHB go up and the line follows IP. MSI-X: IP goes up,
    /// and the message goes as soon as interrupts are enabled and the
    /// guest isn't still handling the last one (EHB); sending it clears IP
    /// (xHCI §4.17.5) and sets EHB. EHB is never set for a message that
    /// wasn't sent, or nothing would ever clear it.
    func raise() {
        usbsts |= 0x8                                                                      // EINT
        if msix == nil || !Config.MsixEnabled {
            iman |= 1                                                                      // IP
            erdp |= 0x8                                                                    // EHB
            return
        }
        if erdp & 0x8 == 0 {
            iman |= 1
        }
        deliverMsi()
    }

    /// Sends interrupter 0's pending interrupt, where MSI-X allows it now.
    func deliverMsi() {
        guard let t = msix, Config.MsixEnabled else { return }
        if iman & 3 == 3 && usbcmd & 4 != 0 && erdp & 0x8 == 0 {
            iman &= ~1
            erdp |= 0x8
            t.Signal(0)
        }
    }

    /// The guest consumed events: send what waited for room, and interrupt
    /// again if events are still unread.
    func dequeueMoved() {
        while !waitingEvents.isEmpty && !ringFull() {
            writeEvent(waitingEvents.removeFirst())
        }
        if erdp & 0x8 == 0 && (erdp & ~0xf) != enqueueAddress {
            raise()
        }
    }

    func postCommandCompletion(at trbAddr: uint64, code: uint8, slot: int) {
        var trb = [uint8](repeating: 0, count: 16)
        binary.LittleEndian.PutUint64(&trb, trbAddr, at: 0)
        binary.LittleEndian.PutUint32(&trb, uint32(code) << 24, at: 8)
        binary.LittleEndian.PutUint32(&trb, (uint32(slot) << 24) | (33 << 10), at: 12)
        postEvent(trb)
    }

    func postTransfer(at trbAddr: uint64, code: uint8, residual: uint32, slot: int, dci: int, eventData: bool = false) {
        if Trace && dci > 1 {
            print("[xhci] event: transfer slot \(slot) dci \(dci) code \(code) residual \(residual) trb 0x\(string(trbAddr, radix: 16))")
        }
        var trb = [uint8](repeating: 0, count: 16)
        binary.LittleEndian.PutUint64(&trb, trbAddr, at: 0)
        binary.LittleEndian.PutUint32(&trb, (uint32(code) << 24) | (residual & 0xff_ffff), at: 8)
        binary.LittleEndian.PutUint32(&trb, (uint32(slot) << 24) | (uint32(dci) << 16) | (32 << 10) | (eventData ? 4 : 0), at: 12)
        postEvent(trb)
    }

    // MARK: - Doorbells

    func ring(_ target: int, _ value: uint32) {
        if target == 0 {
            lock.withLock { runCommands() }
            updateIntx()
            return
        }
        let dci = int(value & 0xff)
        kick(slot: target, dci: dci)
    }

    // MARK: - Commands

    func runCommands() {
        if usbcmd & 1 == 0 { return }
        commandRunning = true
        var guardCount = 0
        while commandRunning && guardCount < 256 {
            guardCount += 1
            guard let t = readTrb(commandRing) else { break }
            if t.Cycle != commandCycle { break }
            if t.Kind == 6 {
                // Link: follow it, toggling the cycle if it says so.
                if t.Control & 2 != 0 { commandCycle = !commandCycle }
                commandRing = t.Parameter & ~0xf
                continue
            }
            let (code, slot) = command(t)
            if Trace { print("[xhci] command \(t.Kind) slot \(slot) -> \(code)") }
            postCommandCompletion(at: commandRing, code: code, slot: slot)
            commandRing += 16
        }
        commandRunning = false
    }

    func command(_ t: Trb) -> (uint8, int) {
        let slotId = int(t.Control >> 24)
        switch t.Kind {
        case 9:    // Enable Slot
            for i in 1...Xhci.maxSlots where slots[i] == nil {
                slots[i] = Slot(id: i)
                return (1, i)
            }
            return (9, 0)                                                                  // no slots available
        case 10:   // Disable Slot
            guard validSlot(slotId) else { return (11, slotId) }
            slots[slotId] = nil
            return (1, slotId)
        case 11:   // Address Device
            return (addressDevice(t, slotId), slotId)
        case 12:   // Configure Endpoint
            return (configureEndpoint(t, slotId), slotId)
        case 13:   // Evaluate Context
            return (evaluateContext(t, slotId), slotId)
        case 14:   // Reset Endpoint
            guard validSlot(slotId), let s = slots[slotId] else { return (11, slotId) }
            let dci = int((t.Control >> 16) & 0x1f)
            guard let ep = s.endpoints[dci] else { return (12, slotId) }
            if ep.state != 2 { return (19, slotId) }                                      // context state error
            ep.state = 3
            writeEndpointContext(s, ep)
            return (1, slotId)
        case 15:   // Stop Endpoint
            guard validSlot(slotId), let s = slots[slotId] else { return (11, slotId) }
            let dci = int((t.Control >> 16) & 0x1f)
            guard let ep = s.endpoints[dci] else { return (12, slotId) }
            ep.state = 3
            writeEndpointContext(s, ep)
            return (1, slotId)
        case 16:   // Set TR Dequeue Pointer
            guard validSlot(slotId), let s = slots[slotId] else { return (11, slotId) }
            let dci = int((t.Control >> 16) & 0x1f)
            guard let ep = s.endpoints[dci] else { return (12, slotId) }
            if ep.state == 1 { return (19, slotId) }
            ep.dequeue = t.Parameter & ~0xf
            ep.cycle = t.Parameter & 1 != 0
            writeEndpointContext(s, ep)
            return (1, slotId)
        case 17:   // Reset Device
            guard validSlot(slotId), let s = slots[slotId] else { return (11, slotId) }
            for i in 2..<32 { s.endpoints[i] = nil }
            s.address = 0
            writeSlotState(s, state: 1)
            return (1, slotId)
        case 23:   // No Op
            return (1, 0)
        default:
            return (5, 0)                                                                  // TRB error
        }
    }

    func validSlot(_ id: int) -> bool { id >= 1 && id <= Xhci.maxSlots && slots[id] != nil }

    /// The output device context of a slot, from DCBAA.
    func outputContext(_ id: int) -> uint64 {
        ((try? memory.Load64(device.GuestAddress(dcbaap + uint64(id) * 8))) ?? 0) & ~0x3f
    }

    func addressDevice(_ t: Trb, _ id: int) -> uint8 {
        guard validSlot(id), let s = slots[id] else { return 11 }
        let input = t.Parameter & ~0xf
        guard let slotCtx = try? memory.Read(device.GuestAddress(input + 32), count: 32),
              let ep0 = try? memory.Read(device.GuestAddress(input + 64), count: 32) else { return 5 }
        let portNumber = int((binary.LittleEndian.Uint32(slotCtx, from: 4) >> 16) & 0xff)
        guard portNumber >= 1 && portNumber <= ports.count, let d = ports[portNumber - 1].device else { return 4 }
        s.port = portNumber
        s.device = d
        s.context = outputContext(id)
        let blockSetAddress = t.Control & (1 << 9) != 0
        s.address = blockSetAddress ? 0 : uint8(id)

        var out = slotCtx
        var dw3 = uint32(s.address)
        dw3 |= (blockSetAddress ? uint32(1) : uint32(2)) << 27                          // Default or Addressed
        binary.LittleEndian.PutUint32(&out, dw3, at: 12)
        try? memory.Write(device.GuestAddress(s.context), out)

        let ep = Endpoint(dci: 1, kind: 4, dequeue: binary.LittleEndian.Uint64(ep0, from: 8) & ~0xf, cycle: ep0[8] & 1 != 0)
        ep.state = 1
        s.endpoints[1] = ep
        var ctx = ep0
        ctx[0] = (ctx[0] & ~7) | 1
        try? memory.Write(device.GuestAddress(s.context + 32), ctx)
        return 1
    }

    func configureEndpoint(_ t: Trb, _ id: int) -> uint8 {
        guard validSlot(id), let s = slots[id] else { return 11 }
        if t.Control & (1 << 9) != 0 {
            // Deconfigure: every endpoint but 0 goes.
            for i in 2..<32 { s.endpoints[i] = nil }
            writeSlotState(s, state: 2)
            return 1
        }
        let input = t.Parameter & ~0xf
        guard let control = try? memory.Read(device.GuestAddress(input), count: 32) else { return 5 }
        let drop = binary.LittleEndian.Uint32(control, from: 0)
        let add = binary.LittleEndian.Uint32(control, from: 4)
        for i in 2..<32 {
            if drop & (1 << uint32(i)) != 0 {
                s.endpoints[i] = nil
                if let ctx = try? memory.Read(device.GuestAddress(s.context + uint64(i) * 32), count: 32) {
                    var c = ctx
                    c[0] &= ~7
                    try? memory.Write(device.GuestAddress(s.context + uint64(i) * 32), c)
                }
            }
            if add & (1 << uint32(i)) != 0 {
                guard let ctx = try? memory.Read(device.GuestAddress(input + uint64(i + 1) * 32), count: 32) else { return 5 }
                let kind = (ctx[4] >> 3) & 7
                let ep = Endpoint(dci: i, kind: kind, dequeue: binary.LittleEndian.Uint64(ctx, from: 8) & ~0xf, cycle: ctx[8] & 1 != 0)
                ep.state = 1
                s.endpoints[i] = ep
                var c = ctx
                c[0] = (c[0] & ~7) | 1
                try? memory.Write(device.GuestAddress(s.context + uint64(i) * 32), c)
            }
        }
        if add & 1 != 0, let slotCtx = try? memory.Read(device.GuestAddress(input + 32), count: 32) {
            // The context entries field, from the input slot context.
            if var out = try? memory.Read(device.GuestAddress(s.context), count: 32) {
                out[3] = (out[3] & 0x07) | (slotCtx[3] & 0xf8)
                try? memory.Write(device.GuestAddress(s.context), out)
            }
        }
        writeSlotState(s, state: 3)
        return 1
    }

    func evaluateContext(_ t: Trb, _ id: int) -> uint8 {
        guard validSlot(id), let s = slots[id] else { return 11 }
        let input = t.Parameter & ~0xf
        guard let control = try? memory.Read(device.GuestAddress(input), count: 32) else { return 5 }
        let add = binary.LittleEndian.Uint32(control, from: 4)
        if add & 1 != 0,
           let inSlot = try? memory.Read(device.GuestAddress(input + 32), count: 32),
           var out = try? memory.Read(device.GuestAddress(s.context), count: 32) {
            for i in 4..<6 { out[i] = inSlot[i] }                                          // max exit latency
            for i in 8..<12 { out[i] = (i == 11) ? (out[i] & 0x3f) | (inSlot[i] & 0xc0) : out[i] }
            try? memory.Write(device.GuestAddress(s.context), out)
        }
        if add & 2 != 0,
           let inEp0 = try? memory.Read(device.GuestAddress(input + 64), count: 32),
           var out = try? memory.Read(device.GuestAddress(s.context + 32), count: 32) {
            out[6] = inEp0[6]; out[7] = inEp0[7]                                           // max packet size
            try? memory.Write(device.GuestAddress(s.context + 32), out)
        }
        return 1
    }

    func writeSlotState(_ s: Slot, state: uint32) {
        guard var out = try? memory.Read(device.GuestAddress(s.context), count: 32) else { return }
        var dw3 = binary.LittleEndian.Uint32(out, from: 12)
        dw3 = (dw3 & 0x07ff_ff00) | (state << 27) | uint32(s.address)
        binary.LittleEndian.PutUint32(&out, dw3, at: 12)
        try? memory.Write(device.GuestAddress(s.context), out)
    }

    /// The endpoint's state and dequeue pointer, into its output context.
    func writeEndpointContext(_ s: Slot, _ ep: Endpoint) {
        let at = device.GuestAddress(s.context + uint64(ep.dci) * 32)
        guard var c = try? memory.Read(at, count: 32) else { return }
        c[0] = (c[0] & ~7) | ep.state
        binary.LittleEndian.PutUint64(&c, ep.dequeue | (ep.cycle ? 1 : 0), at: 8)
        try? memory.Write(at, c)
    }

    // MARK: - Transfers

    /// A device has data for an IN endpoint that was waiting: run its
    /// slot's IN endpoints again.
    func wake(_ d: any Peripheral) {
        let targets = lock.withLock { () -> [(int, int)] in
            var out: [(int, int)] = []
            for case let s? in slots where s.device === d {
                for case let ep? in s.endpoints where ep.dci > 1 && ep.dci % 2 == 1 {
                    out.append((s.id, ep.dci))
                }
            }
            return out
        }
        for (slot, dci) in targets {
            kick(slot: slot, dci: dci)
        }
    }

    func kick(slot id: int, dci: int) {
        if Trace && dci > 1 { print("[xhci] doorbell slot \(id) dci \(dci)") }
        let start = lock.withLock { () -> (Slot, Endpoint)? in
            guard id >= 1 && id <= Xhci.maxSlots, let s = slots[id], let ep = s.endpoints[dci] else { return nil }
            if ep.state == 2 || ep.state == 0 { return nil }                               // halted or disabled
            if ep.state == 3 { ep.state = 1 }                                              // a doorbell restarts a stopped one
            if ep.busy {
                ep.again = true
                return nil
            }
            ep.busy = true
            ep.again = false
            return (s, ep)
        }
        guard let (s, ep) = start else {
            if Trace && dci > 1 {
                let why = lock.withLock { () -> string in
                    guard let ep = slots[id]?.endpoints[dci] else { return "no endpoint" }
                    return "state \(ep.state) busy \(ep.busy) again \(ep.again)"
                }
                print("[xhci]   not started: \(why)")
            }
            return
        }
        if Trace && dci > 1 { print("[xhci]   task for slot \(id) dci \(dci)") }
        Task {
            if self.Trace && dci > 1 { print("[xhci]   task running slot \(id) dci \(dci)") }
            await self.run(s, ep)
        }
    }

    /// Runs TDs off one endpoint's ring until it is empty or waiting.
    func run(_ s: Slot, _ ep: Endpoint) async {
        while true {
            let next = lock.withLock { () -> TransferDescriptor? in
                if ep.state != 1 || slots[s.id] !== s {
                    ep.busy = false
                    return nil
                }
                // A doorbell rung while this task was busy is covered:
                // the ring is read again right here.
                ep.again = false
                if let td = collect(ep) { return td }
                ep.busy = false
                return nil
            }
            guard let td = next else { return }
            if Trace && ep.dci > 1 {
                var kinds = ""
                for t in td.trbs { kinds += " \(t.Kind)/len=\(t.Status & 0x1ffff)/ctl=0x\(string(t.Control, radix: 16))" }
                print("[xhci] slot \(s.id) dci \(ep.dci) TD at 0x\(string(ep.dequeue, radix: 16)):\(kinds)")
            }
            let done = await execute(s, ep, td)
            if Trace && ep.dci > 1 { print("[xhci] slot \(s.id) dci \(ep.dci) -> \(done ? "done" : "waiting")") }
            let more = lock.withLock { () -> bool in
                if !done {
                    // Nothing to send yet: keep the TD for when there is.
                    if ep.again {
                        ep.again = false
                        return true
                    }
                    ep.busy = false
                    return false
                }
                return true
            }
            updateIntx()
            if !more { return }
        }
    }

    /// The next whole TD on the ring, or nil if the guest hasn't finished
    /// writing one. A control transfer's setup, data and status stages
    /// come as one.
    func collect(_ ep: Endpoint) -> TransferDescriptor? {
        var at = ep.dequeue
        var cycle = ep.cycle
        var trbs: [Trb] = []
        var inControl = false
        for _ in 0..<1024 {
            guard let t = readTrb(at) else { return nil }
            if t.Cycle != cycle { return nil }
            if t.Kind == 6 {
                if t.Control & 2 != 0 { cycle = !cycle }
                at = t.Parameter & ~0xf
                continue
            }
            trbs.append(t)
            at += 16
            if ep.kind == 4 {
                if t.Kind == 2 { inControl = true }
                if t.Kind == 4 { inControl = false }
            }
            if !inControl && t.Control & 0x10 == 0 {
                return TransferDescriptor(trbs: trbs, next: at, nextCycle: cycle)
            }
        }
        return nil
    }

    func readTrb(_ at: uint64) -> Trb? {
        guard at != 0, let b = try? memory.Read(device.GuestAddress(at), count: 16) else { return nil }
        return Trb(Address: at, Parameter: binary.LittleEndian.Uint64(b, from: 0), Status: binary.LittleEndian.Uint32(b, from: 8), Control: binary.LittleEndian.Uint32(b, from: 12))
    }

    /// Carries out a TD. False means the device had nothing yet and the TD
    /// stays on the ring.
    func execute(_ s: Slot, _ ep: Endpoint, _ td: TransferDescriptor) async -> bool {
        guard let d = s.device else { return finish(s, ep, td, transferred: 0, code: 4) }
        let buffers = td.trbs.filter { $0.Kind == 1 || $0.Kind == 3 || $0.Kind == 5 }
        let length = buffers.reduce(0) { $0 + int($1.Status & 0x1ffff) }

        if ep.kind == 4 {
            guard let setupTrb = td.trbs.first(where: { $0.Kind == 2 }) else {
                return finish(s, ep, td, transferred: 0, code: 5)
            }
            let p = setupTrb.Parameter
            let setup = Setup(requestType: uint8(p & 0xff), request: uint8((p >> 8) & 0xff),
                              value: uint16((p >> 16) & 0xffff), index: uint16((p >> 32) & 0xffff),
                              length: uint16((p >> 48) & 0xffff))
            var outData: [uint8] = []
            if !setup.DeviceToHost && length > 0 {
                outData = gather(buffers)
            }
            switch control(s, d, setup, outData) {
            case .data(let bytes):
                var n = 0
                if setup.DeviceToHost {
                    let reply = Array(bytes.prefix(min(int(setup.Length), length)))
                    scatter(reply, buffers)
                    n = reply.count
                } else {
                    n = outData.count
                }
                return finish(s, ep, td, transferred: n, code: 1)
            case .nak, .stall:
                return finish(s, ep, td, transferred: 0, code: 6)
            }
        }

        let number = uint8(ep.dci / 2)
        if ep.dci % 2 == 1 {
            switch await d.In(endpoint: number, max: length) {
            case .nak:
                return false
            case .stall:
                return finish(s, ep, td, transferred: 0, code: 6)
            case .data(let bytes):
                let reply = Array(bytes.prefix(length))
                scatter(reply, buffers)
                return finish(s, ep, td, transferred: reply.count, code: 1)
            }
        }
        let data = gather(buffers)
        switch await d.Out(endpoint: number, data) {
        case .nak:
            return false
        case .stall:
            return finish(s, ep, td, transferred: 0, code: 6)
        case .data:
            return finish(s, ep, td, transferred: data.count, code: 1)
        }
    }

    /// Standard requests to the device are the controller's; the rest are
    /// the device's own.
    func control(_ s: Slot, _ d: any Peripheral, _ setup: Setup, _ data: [uint8]) -> Transfer {
        if setup.Kind != 0 || setup.Recipient != 0 {
            return d.Control(setup, data)
        }
        switch setup.Request {
        case 0x00: return .data([1, 0])                                                   // GET_STATUS: self-powered
        case 0x01, 0x03, 0x05: return .data([])                                           // CLEAR/SET_FEATURE, SET_ADDRESS
        case 0x06:
            let index = setup.Value & 0xff
            switch setup.Value >> 8 {
            case 1: return .data(d.DeviceDescriptor)
            case 2: return .data(d.ConfigurationDescriptor)
            case 3:
                switch index {
                case 0: return .data([4, 3, 0x09, 0x04])                                  // English (US)
                case 1: return .data(stringDescriptor("Vertex"))
                case 2: return .data(stringDescriptor(d.Product))
                case 3: return .data(stringDescriptor("VTX\(s.port)0001"))
                default: return .stall
                }
            case 6:
                // Device qualifier: only a high-speed device has one.
                if d.Speed == 3 { return .data([10, 6, 0x00, 0x02, 0, 0, 0, 64, 1, 0]) }
                return .stall
            default:
                return .stall
            }
        case 0x08: return .data([s.configuration])
        case 0x09:
            s.configuration = uint8(setup.Value & 0xff)
            return .data([])
        case 0x0a: return .data([0])
        case 0x0b: return .data([])
        default: return .stall
        }
    }

    func gather(_ buffers: [Trb]) -> [uint8] {
        var out: [uint8] = []
        for t in buffers {
            let n = int(t.Status & 0x1ffff)
            if n == 0 { continue }
            if t.Control & 0x40 != 0 {
                // Immediate data: the bytes are the parameter itself.
                for i in 0..<min(n, 8) { out.append(uint8((t.Parameter >> (8 * uint64(i))) & 0xff)) }
            } else if let b = try? memory.Read(device.GuestAddress(t.Parameter), count: n) {
                out.append(contentsOf: b)
            }
        }
        return out
    }

    func scatter(_ bytes: [uint8], _ buffers: [Trb]) {
        var done = 0
        for t in buffers where done < bytes.count {
            let n = min(int(t.Status & 0x1ffff), bytes.count - done)
            if n == 0 { continue }
            try? memory.Write(device.GuestAddress(t.Parameter), Array(bytes[done..<done + n]))
            done += n
        }
    }

    /// Posts the TD's transfer events and moves the ring past it. An event
    /// goes for each TRB with IOC, and for the TRB a short packet ended in
    /// if it has ISP; after a short packet, only the status stage reports.
    func finish(_ s: Slot, _ ep: Endpoint, _ td: TransferDescriptor, transferred: int, code: uint8) -> bool {
        lock.withLock {
            var left = transferred
            var total = 0
            var reported = false
            var short = false
            for t in td.trbs {
                let ioc = t.Control & 0x20 != 0
                switch t.Kind {
                case 1, 3, 5:
                    let len = int(t.Status & 0x1ffff)
                    let chunk = min(left, len)
                    left -= chunk
                    total += chunk
                    let shortHere = chunk < len && !short && code == 1
                    if shortHere { short = true }
                    if code != 1 {
                        continue
                    }
                    if !reported && (ioc || (shortHere && t.Control & 0x4 != 0)) {
                        postTransfer(at: t.Address, code: shortHere || short ? 13 : 1,
                                     residual: uint32(len - chunk), slot: s.id, dci: ep.dci)
                        if short { reported = true }
                    }
                case 7:
                    // Event Data: its parameter, and the bytes moved so far.
                    if ioc && !reported && code == 1 {
                        postTransfer(at: t.Parameter, code: short ? 13 : 1, residual: uint32(total),
                                     slot: s.id, dci: ep.dci, eventData: true)
                    }
                case 4:
                    reported = false
                    short = false
                    if ioc && code == 1 {
                        postTransfer(at: t.Address, code: 1, residual: 0, slot: s.id, dci: ep.dci)
                    }
                default:
                    if ioc && code == 1 {
                        postTransfer(at: t.Address, code: 1, residual: 0, slot: s.id, dci: ep.dci)
                    }
                }
            }
            if code != 1 {
                // A stall or error halts the endpoint on the TD's last TRB.
                if let last = td.trbs.last {
                    postTransfer(at: last.Address, code: code, residual: uint32(max(0, int(last.Status & 0x1ffff))),
                                 slot: s.id, dci: ep.dci)
                }
                ep.state = 2
            }
            ep.dequeue = td.next
            ep.cycle = td.nextCycle
            if code != 1 {
                writeEndpointContext(s, ep)
            }
        }
        return true
    }
}

/// One TRB as the guest wrote it, and where.
struct Trb {
    let Address: uint64
    let Parameter: uint64
    let Status: uint32
    let Control: uint32

    var Cycle: bool { Control & 1 != 0 }
    var Kind: uint32 { (Control >> 10) & 0x3f }
}

struct TransferDescriptor {
    let trbs: [Trb]
    let next: uint64
    let nextCycle: bool
}

/// A root-hub port and what's plugged into it.
final class Port {
    let Number: int
    var device: (any Peripheral)? = nil
    var enabled = false
    var linkState: uint32 = 5          // RxDetect
    var changes: uint32 = 0
    var wake: uint32 = 0

    init(number: int) {
        Number = number
    }

    /// Power-on, or a device arriving: connected, not yet enabled.
    func connect() {
        enabled = false
        if device != nil {
            linkState = 7              // Polling, until the port is reset
            changes = 1 << 17          // CSC
        } else {
            linkState = 5
            changes = 0
        }
    }

    func portsc() -> uint32 {
        var v: uint32 = 1 << 9         // PP
        if let d = device {
            v |= 1                                                                         // CCS
            v |= uint32(d.Speed) << 10
        }
        if enabled { v |= 2 }
        v |= linkState << 5
        v |= changes
        v |= wake
        return v
    }
}

/// A device slot: the device it addresses and its endpoints by DCI.
final class Slot {
    let id: int
    var port = 0
    var device: (any Peripheral)? = nil
    var context: uint64 = 0
    var address: uint8 = 0
    var configuration: uint8 = 0
    var endpoints: [Endpoint?] = [Endpoint?](repeating: nil, count: 32)

    init(id: int) {
        self.id = id
    }
}

/// One endpoint's transfer ring and state (0 disabled, 1 running,
/// 2 halted, 3 stopped).
final class Endpoint {
    let dci: int
    /// The endpoint type from its context: 2 bulk out, 3 interrupt out,
    /// 4 control, 6 bulk in, 7 interrupt in.
    let kind: uint8
    var dequeue: uint64
    var cycle: bool
    var state: uint8 = 0
    var busy = false
    var again = false

    init(dci: int, kind: uint8, dequeue: uint64, cycle: bool) {
        self.dci = dci
        self.kind = kind
        self.dequeue = dequeue
        self.cycle = cycle
    }
}
