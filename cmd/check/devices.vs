import (
    "encoding/binary"
    "fs/mmap"
    "vm/acpi"
    "vm/device"
    "vm/disk"
    "vm/nvme"
    "vm/pci"
    "vm/usb"
)

/// Guest memory of `size` bytes at `base`, for a device to DMA into.
func scratchMemory(base: uint64, size: uint64) throws -> (device.GuestMemory, mmap.Mapping) {
    let mapping = try mmap.Anonymous(int(size))
    let region = device.Region(guest: device.GuestAddress(base), count: size, host: mapping.RawPointer!)
    return (device.GuestMemory([region]), mapping)
}

final class RecordingIntx {
    let lines: [device.RecordingIrq] = [device.RecordingIrq(), device.RecordingIrq(), device.RecordingIrq(), device.RecordingIrq()]
    func line(_ n: uint32) -> device.RecordingIrq { lines[int(n % 4)] }
}

final class BarProbe: pci.Function {
    let Config = pci.ConfigSpace(vendor: 0x1234, device: 0x5678, classCode: pci.ClassCode.other, revision: 1)
    let Bars = [pci.Bar(index: 0, size: 0x4000, kind: .memory64, prefetchable: false)]
    var lastRead: uint64 = ~0
    func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64 {
        lastRead = offset
        return 0x5a5a
    }
    func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64) {}
}

func pciLayout() -> pci.Layout {
    pci.Layout(
        ecam: device.Range(base: 0x1000_0000, count: 0x1000_0000),
        mmio32: device.Range(base: 0x2000_0000, count: 0x1000_0000),
        mmio64: device.Range(base: 0x4_0000_0000, count: 0x4_0000_0000),
        irqBase: 3
    )
}

func checkPci() {
    let lines = RecordingIntx()
    let layout = pciLayout()
    let root = pci.Root(layout, intx: { lines.line($0) })
    let f = BarProbe()
    guard let slot = try? root.Attach(f) else {
        check(false, "PCI: attach a function")
        return
    }
    let cfg = uint64(slot) << 15

    // Read-only fields ignore writes; the ROM BAR answers 0.
    root.Write(offset: cfg | 0x00, size: 4, value: 0xdead_beef)
    check(root.Read(offset: cfg | 0x00, size: 4) == 0x5678_1234, "PCI: vendor/device ID are read-only")
    root.Write(offset: cfg | 0x30, size: 4, value: 0xffff_fffe)
    check(root.Read(offset: cfg | 0x30, size: 4) == 0, "PCI: no expansion ROM (ROM BAR reads 0)")

    // The guest moves BAR 0, and the aperture follows it once decoding is on.
    root.Write(offset: cfg | 0x10, size: 4, value: 0x2100_0000)
    root.Write(offset: cfg | 0x14, size: 4, value: 0)
    let window = root.MmioWindow(layout.Mmio32)
    check(window.Read(offset: 0x0100_0010, size: 4) == 0xffff_ffff, "PCI: BARs don't decode with memory space off")
    root.Write(offset: cfg | 0x04, size: 2, value: 0x0006)
    check(window.Read(offset: 0x0100_0010, size: 4) == 0x5a5a && f.lastRead == 0x10,
          "PCI: an access at a moved BAR reaches the function")

    // INTx: level, through the swizzle, masked by interrupt disable.
    let line = lines.line(root.IntxLine(slot: slot))
    f.Config.SetIntx(true)
    check(line.Level, "PCI: INTx asserts its swizzled line")
    root.Write(offset: cfg | 0x04, size: 2, value: 0x0406)
    check(!line.Level, "PCI: interrupt disable masks INTx")
    check(root.Read(offset: cfg | 0x06, size: 2) & 0x08 != 0, "PCI: status still reports the pending interrupt")
    root.Write(offset: cfg | 0x04, size: 2, value: 0x0006)
    check(line.Level, "PCI: clearing interrupt disable raises it again")
    f.Config.SetIntx(false)
    check(!line.Level, "PCI: deasserting INTx lowers the line")
}

/// Polls until `done` holds or a second passes: device work runs in tasks.
func settle(_ done: () -> bool) async -> bool {
    for _ in 0..<1000 {
        if done() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return done()
}

func checkNvme() async {
    let base: uint64 = 0x4000_0000
    guard let (mem, mapping) = try? scratchMemory(base: base, size: 0x10_0000) else {
        check(false, "NVMe: guest memory")
        return
    }
    _ = mapping
    let lines = RecordingIntx()
    let root = pci.Root(pciLayout(), intx: { lines.line($0) })
    let image = disk.MemoryImage(size: 1 << 20)
    let ctrl = nvme.Controller(memory: mem)
    ctrl.Attach(image)
    guard let slot = try? root.Attach(ctrl) else {
        check(false, "NVMe: attach")
        return
    }
    let intx = lines.line(root.IntxLine(slot: slot))
    func at(_ off: uint64) -> device.GuestAddress { device.GuestAddress(base + off) }

    // Admin queues: 16 entries each.
    ctrl.WriteBar(0, offset: 0x24, size: 4, value: (15 << 16) | 15)
    ctrl.WriteBar(0, offset: 0x28, size: 8, value: base + 0x1000)
    ctrl.WriteBar(0, offset: 0x30, size: 8, value: base + 0x2000)
    ctrl.WriteBar(0, offset: 0x14, size: 4, value: 1)
    check(ctrl.ReadBar(0, offset: 0x1c, size: 4) & 1 == 1, "NVMe: CSTS.RDY after CC.EN")

    var sqTail: [uint64] = [0, 0]
    var cqHead: [uint64] = [0, 0]
    let sqBase: [uint64] = [0x1000, 0x5000]
    let cqBase: [uint64] = [0x2000, 0x4000]

    func submit(_ q: int, _ dwords: [uint32]) {
        var e = [uint8](repeating: 0, count: 64)
        for (i, d) in dwords.enumerated() { binary.LittleEndian.PutUint32(&e, d, at: i * 4) }
        try? mem.Write(at(sqBase[q] + sqTail[q] * 64), e)
        sqTail[q] = (sqTail[q] + 1) % 16
        ctrl.WriteBar(0, offset: 0x1000 + uint64(q) * 8, size: 4, value: sqTail[q])
    }

    /// Waits for the next completion on queue q; its status, then frees it.
    func complete(_ q: int) async -> uint16? {
        let entry = at(cqBase[q] + cqHead[q] * 16)
        let phase: uint16 = 1
        let ok = await settle { ((try? mem.Load16(entry.Adding(14))) ?? 0) & 1 == phase }
        if !ok { return nil }
        let status = ((try? mem.Load16(entry.Adding(14))) ?? 0) >> 1
        cqHead[q] += 1
        ctrl.WriteBar(0, offset: 0x1000 + uint64(q) * 8 + 4, size: 4, value: cqHead[q])
        return status
    }

    // Identify Controller (CNS 1). PRP1 at base + 0x3000.
    submit(0, [0x0001_0006, 0, 0, 0, 0, 0, uint32(truncatingIfNeeded: base + 0x3000), uint32((base + 0x3000) >> 32), 0, 0, 1])
    let raised = await settle { intx.Level }
    check(raised, "NVMe: a completion asserts INTx")
    check(await complete(0) == 0, "NVMe: Identify Controller succeeds")
    check(!intx.Level, "NVMe: the CQ head doorbell deasserts INTx")
    let ident = (try? mem.Read(at(0x3000), count: 4096)) ?? []
    check(ident.count == 4096 && binary.LittleEndian.Uint16(ident, from: 0) == 0x1b36 && binary.LittleEndian.Uint32(ident, from: 516) == 1 && ident[77] == 7,
          "NVMe: Identify Controller reports VID, one namespace, MDTS")

    // Identify Namespace 1: 2048 blocks of 512 bytes.
    submit(0, [0x0002_0006, 1, 0, 0, 0, 0, uint32(truncatingIfNeeded: base + 0x3000), uint32((base + 0x3000) >> 32), 0, 0, 0])
    check(await complete(0) == 0, "NVMe: Identify Namespace succeeds")
    let ns = (try? mem.Read(at(0x3000), count: 4096)) ?? []
    check(ns.count == 4096 && binary.LittleEndian.Uint64(ns, from: 0) == 2048 && ns[130] == 9, "NVMe: namespace size and 512-byte LBA format")

    // I/O queue pair 1.
    submit(0, [0x0003_0005, 0, 0, 0, 0, 0, uint32(truncatingIfNeeded: base + 0x4000), uint32((base + 0x4000) >> 32), 0, 0, (15 << 16) | 1, 0x3])
    check(await complete(0) == 0, "NVMe: Create I/O Completion Queue")
    submit(0, [0x0004_0001, 0, 0, 0, 0, 0, uint32(truncatingIfNeeded: base + 0x5000), uint32((base + 0x5000) >> 32), 0, 0, (15 << 16) | 1, (1 << 16) | 1])
    check(await complete(0) == 0, "NVMe: Create I/O Submission Queue")

    // Write 3 pages through a PRP list: PRP1 a page, PRP2 a list of two.
    var pattern = [uint8](repeating: 0, count: 12288)
    for i in 0..<pattern.count { pattern[i] = uint8(truncatingIfNeeded: i * 7 + 3) }
    try? mem.Write(at(0x8000), Array(pattern[0..<4096]))
    try? mem.Write(at(0xa000), Array(pattern[4096..<8192]))
    try? mem.Write(at(0xb000), Array(pattern[8192..<12288]))
    try? mem.Store64(at(0x9000), base + 0xa000)
    try? mem.Store64(at(0x9008), base + 0xb000)
    submit(1, [0x0010_0001, 1, 0, 0, 0, 0, uint32(truncatingIfNeeded: base + 0x8000), uint32((base + 0x8000) >> 32),
               uint32(truncatingIfNeeded: base + 0x9000), uint32((base + 0x9000) >> 32), 4, 0, 23])
    check(await complete(1) == 0, "NVMe: Write of 24 blocks through a PRP list")

    // Read them back into one buffer, through a list of its own.
    try? mem.Store64(at(0x9800), base + 0xd000)
    try? mem.Store64(at(0x9808), base + 0xe000)
    submit(1, [0x0011_0002, 1, 0, 0, 0, 0, uint32(truncatingIfNeeded: base + 0xc000), uint32((base + 0xc000) >> 32),
               uint32(truncatingIfNeeded: base + 0x9800), uint32((base + 0x9800) >> 32), 4, 0, 23])
    let readOk = await complete(1) == 0
    let back = ((try? mem.Read(at(0xc000), count: 4096)) ?? []) + ((try? mem.Read(at(0xd000), count: 4096)) ?? []) + ((try? mem.Read(at(0xe000), count: 4096)) ?? [])
    check(readOk && back == pattern, "NVMe: Read returns what was written, across list pages")

    // Out of range.
    submit(1, [0x0012_0002, 1, 0, 0, 0, 0, uint32(truncatingIfNeeded: base + 0xc000), 0, 0, 0, 2047, 0, 1])
    check(await complete(1) == nvme.Status.lbaOutOfRange, "NVMe: a read past the end is LBA Out of Range")
}

func checkUsbStorage() async {
    var bytes = [uint8](repeating: 0, count: 8 * 2048)
    for i in 2048..<4096 { bytes[i] = 0xcd }
    let cd = usb.Storage(disk.MemoryImage(bytes: bytes, readOnly: true), kind: .cdrom)

    func cbw(_ tag: uint32, _ length: uint32, _ dirIn: bool, _ cdb: [uint8]) -> [uint8] {
        var c = [uint8](repeating: 0, count: 31)
        binary.LittleEndian.PutUint32(&c, 0x4342_5355, at: 0)
        binary.LittleEndian.PutUint32(&c, tag, at: 4)
        binary.LittleEndian.PutUint32(&c, length, at: 8)
        c[12] = dirIn ? 0x80 : 0
        c[14] = uint8(cdb.count)
        for i in 0..<cdb.count { c[15 + i] = cdb[i] }
        return c
    }

    func csw(_ t: usb.Transfer) -> (uint32, uint32, uint8)? {
        guard case .data(let d) = t, d.count == 13, binary.LittleEndian.Uint32(d, from: 0) == 0x5342_5355 else { return nil }
        return (binary.LittleEndian.Uint32(d, from: 4), binary.LittleEndian.Uint32(d, from: 8), d[12])
    }

    _ = await cd.Out(endpoint: 2, cbw(7, 36, true, [0x12, 0, 0, 0, 36, 0]))
    if case .data(let inq) = await cd.In(endpoint: 1, max: 512) {
        check(inq.count == 36 && inq[0] == 0x05 && inq[1] & 0x80 != 0, "USB storage: INQUIRY says removable CD-ROM")
    } else {
        check(false, "USB storage: INQUIRY data")
    }
    if let (tag, residue, status) = csw(await cd.In(endpoint: 1, max: 512)) {
        check(tag == 7 && residue == 0 && status == 0, "USB storage: INQUIRY CSW good, tag echoed")
    } else {
        check(false, "USB storage: INQUIRY CSW")
    }

    _ = await cd.Out(endpoint: 2, cbw(8, 8, true, [0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    if case .data(let cap) = await cd.In(endpoint: 1, max: 512) {
        check(cap.count == 8 && cap[3] == 7 && cap[6] == 0x08, "USB storage: READ CAPACITY is 8 blocks of 2048")
    }
    _ = await cd.In(endpoint: 1, max: 512)

    _ = await cd.Out(endpoint: 2, cbw(9, 2048, true, [0x28, 0, 0, 0, 0, 1, 0, 0, 1, 0]))
    if case .data(let block) = await cd.In(endpoint: 1, max: 65536) {
        check(block.count == 2048 && block.allSatisfy({ $0 == 0xcd }), "USB storage: READ(10) returns block 1")
    }
    _ = await cd.In(endpoint: 1, max: 512)

    _ = await cd.Out(endpoint: 2, cbw(10, 2048, false, [0x2a, 0, 0, 0, 0, 1, 0, 0, 1, 0]))
    _ = await cd.Out(endpoint: 2, [uint8](repeating: 0, count: 2048))
    if let (_, _, status) = csw(await cd.In(endpoint: 1, max: 512)) {
        check(status == 1, "USB storage: a WRITE to a CD-ROM fails")
    }
    _ = await cd.Out(endpoint: 2, cbw(11, 18, true, [0x03, 0, 0, 0, 18, 0]))
    if case .data(let sense) = await cd.In(endpoint: 1, max: 512) {
        check(sense.count == 18 && sense[2] == 7 && sense[12] == 0x27, "USB storage: REQUEST SENSE says write protected")
    }
    _ = await cd.In(endpoint: 1, max: 512)

    _ = await cd.Out(endpoint: 2, cbw(12, 64, true, [0x43, 0, 0, 0, 0, 0, 0, 0, 64, 0]))
    if case .data(let toc) = await cd.In(endpoint: 1, max: 512) {
        check(toc.count == 20 && toc[2] == 1 && toc[3] == 1 && toc[14] == 0xaa, "USB storage: READ TOC has track 1 and the lead-out")
    }
    _ = await cd.In(endpoint: 1, max: 512)
}

func checkXhci() async {
    let base: uint64 = 0x4000_0000
    guard let (mem, mapping) = try? scratchMemory(base: base, size: 0x10_0000) else {
        check(false, "xHCI: guest memory")
        return
    }
    _ = mapping
    let lines = RecordingIntx()
    let root = pci.Root(pciLayout(), intx: { lines.line($0) })
    let x = usb.Xhci(memory: mem)
    let kbd = usb.Keyboard()
    check(x.Plug(kbd) == 1, "xHCI: the keyboard is on port 1")
    guard let slot = try? root.Attach(x) else {
        check(false, "xHCI: attach")
        return
    }
    let intx = lines.line(root.IntxLine(slot: slot))
    func at(_ off: uint64) -> device.GuestAddress { device.GuestAddress(base + off) }

    let portsc = x.ReadBar(0, offset: 0x440, size: 4)
    check(portsc & 1 == 1 && (portsc >> 10) & 0xf == 1 && portsc & (1 << 17) != 0,
          "xHCI: port 1 connected, full speed, connect change")

    // Event ring: one segment of 16 TRBs at 0x2000; command ring at 0x1000.
    try? mem.Store64(at(0x3000), base + 0x2000)
    try? mem.Store32(at(0x3008), 16)
    x.WriteBar(0, offset: 0x1028, size: 4, value: 1)
    x.WriteBar(0, offset: 0x1038, size: 8, value: base + 0x2000)
    x.WriteBar(0, offset: 0x1030, size: 8, value: base + 0x3000)
    x.WriteBar(0, offset: 0x1020, size: 4, value: 2)                     // IMAN.IE
    x.WriteBar(0, offset: 0x58, size: 8, value: (base + 0x1000) | 1)     // CRCR, cycle 1
    x.WriteBar(0, offset: 0x70, size: 8, value: base + 0x4000)           // DCBAAP
    x.WriteBar(0, offset: 0x40, size: 4, value: 0x5)                     // run, interrupts on
    check(x.ReadBar(0, offset: 0x44, size: 4) & 1 == 0, "xHCI: running clears HCHalted")

    // Enable Slot, then a No-Op.
    try? mem.Store32(at(0x100c), (9 << 10) | 1)
    try? mem.Store32(at(0x101c), (23 << 10) | 1)
    x.WriteBar(0, offset: 0x2000, size: 4, value: 0)
    let ev = (try? mem.Read(at(0x2000), count: 32)) ?? []
    check(ev.count == 32 && binary.LittleEndian.Uint64(ev, from: 0) == base + 0x1000 && ev[11] == 1 && (binary.LittleEndian.Uint32(ev, from: 12) >> 10) & 0x3f == 33
          && ev[15] == 1 && ev[12] & 1 == 1, "xHCI: Enable Slot completes with slot 1")
    check(ev.count == 32 && binary.LittleEndian.Uint64(ev, from: 16) == base + 0x1010 && ev[27] == 1, "xHCI: the No-Op completes after it")
    check(intx.Level, "xHCI: events assert INTx")
    x.WriteBar(0, offset: 0x1020, size: 4, value: 3)                     // clear IP
    check(!intx.Level, "xHCI: clearing IMAN.IP deasserts INTx")

    // Port reset enables the port and reports it with an event.
    x.WriteBar(0, offset: 0x440, size: 4, value: 0x10 | 0x200)
    let after = x.ReadBar(0, offset: 0x440, size: 4)
    check(after & 2 != 0 && (after >> 5) & 0xf == 0 && after & (1 << 21) != 0, "xHCI: port reset enables the port (U0, PRC)")
    let psc = (try? mem.Read(at(0x2020), count: 16)) ?? []
    check(psc.count == 16 && (binary.LittleEndian.Uint32(psc, from: 12) >> 10) & 0x3f == 34 && psc[3] == 1, "xHCI: a Port Status Change event for port 1")
}

func checkAcpiFixes() {
    let payload = acpi.BuildArm64(acpi.Arm64Config(vcpus: 4, virtioCount: 0))
    let t = payload.Tables
    func find(_ sig: string) -> int? {
        let s = Array(sig.utf8)
        var i = 0
        while i + 4 <= t.count {
            if t[i] == s[0] && t[i + 1] == s[1] && t[i + 2] == s[2] && t[i + 3] == s[3] { return i }
            i += 16
        }
        return nil
    }
    if let f = find("FACP") {
        check(t[f + 9] == 0, "ACPI: the FADT's checksum is left 0 for the loader to compute")
    }
    check(payload.Rsdp[8] == 0 && payload.Rsdp[32] == 0, "ACPI: the RSDP's checksums are left 0 for the loader")
    if let m = find("APIC") {
        let length = int(binary.LittleEndian.Uint32(t, from: m + 4))
        var at = m + 44
        var gicc = 0
        var sane = true
        while at < m + length {
            let len = int(t[at + 1])
            if len == 0 { sane = false; break }
            if t[at] == 0x0b {
                gicc += 1
                sane = sane && len == 80
            }
            at += len
        }
        check(sane && at == m + length && gicc == 4, "ACPI: MADT entries tile the table; 4 GICCs of 80 bytes")
    }
    if let g = find("GTDT") {
        check(binary.LittleEndian.Uint32(t, from: g + 4) == 104, "ACPI: GTDT revision 3 is 104 bytes")
    }
}

final class RecordingMsi: device.Msi {
    var sent: [(uint64, uint32)] = []
    func Send(address: uint64, data: uint32) { sent.append((address, data)) }
}

/// NVMe on MSI-X: the guest enables it in config space, programs a vector,
/// and a completion sends that message instead of raising INTx.
func checkNvmeMsix() async {
    let base: uint64 = 0x4000_0000
    guard let (mem, mapping) = try? scratchMemory(base: base, size: 0x10_0000) else {
        check(false, "NVMe MSI-X: guest memory")
        return
    }
    _ = mapping
    let lines = RecordingIntx()
    let msi = RecordingMsi()
    let root = pci.Root(pciLayout(), intx: { lines.line($0) })
    let ctrl = nvme.Controller(memory: mem, msi: msi)
    ctrl.Attach(disk.MemoryImage(size: 1 << 20))
    guard let slot = try? root.Attach(ctrl) else { return }
    let cfg = uint64(slot) << 15
    var cap = int(root.Read(offset: cfg | 0x34, size: 1))
    var msixAt = 0
    while cap != 0 {
        if root.Read(offset: cfg | uint64(cap), size: 1) == 0x11 { msixAt = cap }
        cap = int(root.Read(offset: cfg | uint64(cap + 1), size: 1))
    }
    check(msixAt != 0 && root.Read(offset: cfg | uint64(msixAt + 2), size: 2) & 0x7ff == 16, "NVMe MSI-X: capability with 17 vectors")
    root.Write(offset: cfg | uint64(msixAt + 2), size: 2, value: 0x8000)
    root.Write(offset: cfg | 0x04, size: 2, value: 0x0406)

    // Vector 0: the frame's SETSPI address, SPI 130, unmasked.
    ctrl.WriteBar(0, offset: 0x2000, size: 4, value: 0x0802_0040)
    ctrl.WriteBar(0, offset: 0x2008, size: 4, value: 130)
    ctrl.WriteBar(0, offset: 0x200c, size: 4, value: 0)

    ctrl.WriteBar(0, offset: 0x24, size: 4, value: (15 << 16) | 15)
    ctrl.WriteBar(0, offset: 0x28, size: 8, value: base + 0x1000)
    ctrl.WriteBar(0, offset: 0x30, size: 8, value: base + 0x2000)
    ctrl.WriteBar(0, offset: 0x14, size: 4, value: 1)
    var e = [uint8](repeating: 0, count: 64)
    binary.LittleEndian.PutUint32(&e, 0x0001_0006, at: 0)
    binary.LittleEndian.PutUint64(&e, base + 0x3000, at: 24)
    binary.LittleEndian.PutUint32(&e, 1, at: 40)
    try? mem.Write(device.GuestAddress(base + 0x1000), e)
    ctrl.WriteBar(0, offset: 0x1000, size: 4, value: 1)
    // The admin queue answers before the doorbell write returns.
    check(msi.sent.count == 1 && msi.sent[0].0 == 0x0802_0040 && msi.sent[0].1 == 130,
          "NVMe MSI-X: an admin completion sends vector 0's message, synchronously")
    check(!lines.line(root.IntxLine(slot: slot)).Level, "NVMe MSI-X: INTx stays low while MSI-X is on")
}
