// cmd/check: offline verification of device models, boot headers, queues, and FDT/ACPI.
package main

import (
    "compress/gzip"
    "encoding/fdt"
    "fs"
    "fs/mmap"
    "io"
    "sync"
    "vm"
    "vm/acpi"
    "vm/boot"
    "vm/chipset"
    "vm/device"
    "vm/disk"
    "vm/display"
    "vm/pci"
    "vm/virtio"
    "vm/windows"
    "net/ether"
    "net/nat"
    "net/wire"
)

var failures = 0

func check(_ ok: bool, _ what: string) {
    if ok {
        print("ok    \(what)")
    } else {
        print("FAIL  \(what)")
        failures += 1
    }
}

final class BufferWriter: io.AsyncWriter {
    var bytes: [uint8] = []
    let lock = sync.Mutex()

    func Write(_ b: borrowing [uint8]) async throws {
        lock.withLock { bytes.append(contentsOf: b) }
    }

    func Flush() async throws {}
}

func main() async -> int32 {
    print("--- vm offline checks ---")

    // 1. PL011 UART test
    let writer = BufferWriter()
    let irq = device.RecordingIrq()
    let uart = chipset.Pl011(output: writer, irq: irq)

    // Check PrimeCell ID registers
    check(uart.Read(offset: 0xfe0, size: 4) == 0x11, "PL011 PrimeCell ID 0")
    check(uart.Read(offset: 0xfe4, size: 4) == 0x10, "PL011 PrimeCell ID 1")

    // Write a character
    uart.Write(offset: 0x000, size: 4, value: 0x41) // 'A'

    // Feed RX bytes
    uart.Feed([0x48, 0x69]) // "Hi"
    check(uart.Read(offset: 0x000, size: 4) == 0x48, "PL011 RX first byte 'H'")
    check(uart.Read(offset: 0x000, size: 4) == 0x69, "PL011 RX second byte 'i'")
    check(uart.Read(offset: 0x000, size: 4) == 0x00, "PL011 RX empty returns 0")

    // 2. PL031 RTC test
    let rtc = chipset.Pl031(irq: device.NoIrq(), localTime: false)
    let rtcTime = rtc.Read(offset: 0x000, size: 4)
    check(rtcTime > 0, "PL031 RTC returns current time")

    // 3. ARM64 Image header parser test
    var dummyHeader = [uint8](repeating: 0, count: 64)
    // Magic "ARM\x64" at offset 0x38 = 0x644d5241
    dummyHeader[0x38] = 0x41
    dummyHeader[0x39] = 0x52
    dummyHeader[0x3a] = 0x4d
    dummyHeader[0x3b] = 0x64
    // Text offset at offset 8 = 0x80000
    dummyHeader[8] = 0x00
    dummyHeader[9] = 0x00
    dummyHeader[10] = 0x08
    dummyHeader[11] = 0x00
    // Image size at offset 16 = 0x200000
    dummyHeader[16] = 0x00
    dummyHeader[17] = 0x00
    dummyHeader[18] = 0x20
    dummyHeader[19] = 0x00

    do {
        let hdr = try boot.ParseImageHeader(dummyHeader)
        check(hdr.TextOffset == 0x80000, "Image header text_offset parsed correctly")
        check(hdr.ImageSize == 0x200000, "Image header image_size parsed correctly")
    } catch {
        check(false, "ParseImageHeader threw: \(error)")
    }

    // 4. LinuxArm64 boot planner test
    do {
        let ram = device.Range(base: 0x4000_0000, count: 512 << 20)
        let dummyInitrd: [uint8] = [1, 2, 3, 4]
        let plan = try boot.LinuxArm64(
            kernel: dummyHeader,
            initrd: dummyInitrd,
            cmdline: "console=ttyAMA0",
            ram: ram
        )
        check(plan.Loads.count == 2, "Boot plan has 2 loads (kernel + initrd)")
        check(plan.DeviceTree != nil, "Boot plan assigned DeviceTree address")
        switch plan.Entry {
        case .arm64(let pc, let x0):
            check(pc >= ram.Base, "Entry PC within RAM")
            check(x0 == plan.DeviceTree!.Value, "Entry X0 points to DeviceTree")
        default:
            check(false, "Expected .arm64 entry mode")
        }
    } catch {
        check(false, "LinuxArm64 boot plan threw: \(error)")
    }

    // 5. ARM64 FDT generator and round-trip decode test
    let fdtBytes = vm.PlatformArm64.BuildFdt(
        vcpus: 2,
        ram: device.Range(base: 0x4000_0000, count: 512 << 20),
        initrd: device.Range(base: 0x4500_0000, count: 1024),
        cmdline: "console=ttyAMA0 root=/dev/vda rw",
        virtioCount: 1
    )
    check(fdtBytes.count > 0, "BuildFdt produced non-empty DTB")
    do {
        let decoded = try fdt.Decode(fdtBytes)
        check(decoded.Root.Child("chosen") != nil, "FDT contains /chosen node")
        check(decoded.Root.Child("cpus") != nil, "FDT contains /cpus node")
        check(decoded.Root.Child("psci") != nil, "FDT contains /psci node")
        check(decoded.Root.Child("timer") != nil, "FDT contains /timer node")
    } catch {
        check(false, "Decode of generated FDT threw: \(error)")
    }

    // 6. VirtIO MMIO transport config tests
    let dummyBuf = [uint8](repeating: 0, count: 4096)
    var dummyHost = [uint8](repeating: 0, count: 4096)
    let region = dummyHost.withUnsafeMutableBytes {
        device.Region(guest: device.GuestAddress(0), count: 4096, host: $0.baseAddress!)
    }
    let guestMem = device.GuestMemory([region])
    let dummyIrq = device.RecordingIrq()
    let rng = virtio.Rng()
    let transport = virtio.MmioTransport(rng, memory: guestMem, irq: dummyIrq)

    let magic = transport.Read(offset: 0x000, size: 4)
    check(magic == 0x7472_6976, "VirtIO MMIO magic is 'virt' (0x74726976)")
    let version = transport.Read(offset: 0x004, size: 4)
    check(version == 2, "VirtIO MMIO version is modern (2)")
    let devId = transport.Read(offset: 0x008, size: 4)
    check(devId == 4, "VirtIO RNG device ID is 4")

    // 7. Display Framebuffer tests
    var fbMemory = [uint8](repeating: 0, count: 16 * 16 * 4)
    // Fill first pixel with XRGB8888 blue: [0xff, 0x00, 0x00, 0x00] (BGRA in memory)
    fbMemory[0] = 0xff // Blue
    fbMemory[1] = 0x00 // Green
    fbMemory[2] = 0x00 // Red
    fbMemory[3] = 0x00 // X
    let fbRegion = fbMemory.withUnsafeMutableBytes {
        device.Region(guest: device.GuestAddress(0x3000_0000), count: 16 * 16 * 4, host: $0.baseAddress!)
    }
    let fbGuestMem = device.GuestMemory([fbRegion])
    let fb = display.Framebuffer(memory: fbGuestMem)
    fb.Configure(address: device.GuestAddress(0x3000_0000), width: 16, height: 16, stride: 16 * 4, format: .xrgb8888)
    check(fb.Configured, "Framebuffer is configured")
    do {
        let snap = try fb.Snapshot()
        check(snap.count == 16 * 16 * 4, "Framebuffer Snapshot size matches 16x16 RGBA")
        // Check color conversion: BGRA in memory becomes RGBA in snapshot
        check(snap[0] == 0x00, "Pixel 0 Red is 0x00")
        check(snap[1] == 0x00, "Pixel 0 Green is 0x00")
        check(snap[2] == 0xff, "Pixel 0 Blue is 0xff")
        check(snap[3] == 0xff, "Pixel 0 Alpha is 0xff")

        let img = try fb.ToImage()
        check(img != nil, "Framebuffer ToImage produced RGBA image")
        check(img?.Width == 16, "Image width is 16")
        check(img?.Height == 16, "Image height is 16")
    } catch {
        check(false, "Framebuffer Snapshot/ToImage threw: \(error)")
    }

    // 8. FDT with simple-framebuffer test
    let fbFdtBytes = vm.PlatformArm64.BuildFdt(
        vcpus: 1,
        ram: device.Range(base: 0x4000_0000, count: 512 << 20),
        cmdline: "console=ttyAMA0",
        virtioCount: 0,
        framebuffer: vm.FramebufferConfig(base: 0x3000_0000, width: 800, height: 600)
    )
    do {
        let decoded = try fdt.Decode(fbFdtBytes)
        let fbNode = decoded.Root.Child("framebuffer@30000000")
        check(fbNode != nil, "FDT contains framebuffer@30000000 node")
        check(fbNode?.PropertyNamed("compatible") != nil, "compatible property exists on framebuffer")
    } catch {
        check(false, "Decode of FDT with simplefb threw: \(error)")
    }

    // 9. VirtIO Input device test
    let tablet = virtio.Input(.tablet)
    check(tablet.Id.rawValue == 18, "VirtIO Input device ID is 18")

    // Query ID_NAME (select = 1)
    tablet.WriteConfig(offset: 0, size: 2, value: 0x0001) // select=1, subsel=0
    let nameSize = tablet.ReadConfig(offset: 2, size: 1)
    check(nameSize > 0, "VirtIO Input name size is > 0")
    var nameBytes = [uint8]()
    for o in 0..<int(nameSize) {
        let b = uint8(tablet.ReadConfig(offset: 8 + uint64(o), size: 1))
        nameBytes.append(b)
    }
    let nameStr = string(decoding: nameBytes, as: UTF8.self)
    check(nameStr == "Vertex VirtIO Tablet", "VirtIO Input tablet name is 'Vertex VirtIO Tablet'")

    // Query PROP_BITS (select = 0x10)
    tablet.WriteConfig(offset: 0, size: 1, value: 0x10)
    let propVal = tablet.ReadConfig(offset: 8, size: 1)
    check(propVal & 0x02 != 0, "VirtIO Input has INPUT_PROP_DIRECT bit")

    // Query EV_BITS for EV_ABS (select = 0x11, subsel = 3)
    tablet.WriteConfig(offset: 0, size: 2, value: 0x0311)
    let absBits = tablet.ReadConfig(offset: 8, size: 1)
    check(absBits == 0x03, "VirtIO Input EV_ABS supports ABS_X and ABS_Y (0x03)")

    // Query ABS_INFO for ABS_X (select = 0x12, subsel = 0)
    tablet.WriteConfig(offset: 0, size: 2, value: 0x0012)
    let absSize = tablet.ReadConfig(offset: 2, size: 1)
    check(absSize == 20, "VirtIO Input ABS_INFO size is 20 bytes")
    let absMax = tablet.ReadConfig(offset: 12, size: 4) // offset 8 + 4 = 12
    check(absMax == 32767, "VirtIO Input ABS_X max is 32767")

    // 10. VirtIO Keyboard device test
    let kbd = virtio.Input(.keyboard)
    kbd.WriteConfig(offset: 0, size: 2, value: 0x0001) // select=1, subsel=0
    let kbdNameSize = kbd.ReadConfig(offset: 2, size: 1)
    var kbdNameBytes = [uint8]()
    for o in 0..<int(kbdNameSize) {
        let b = uint8(kbd.ReadConfig(offset: 8 + uint64(o), size: 1))
        kbdNameBytes.append(b)
    }
    let kbdNameStr = string(decoding: kbdNameBytes, as: UTF8.self)
    check(kbdNameStr == "Vertex VirtIO Keyboard", "VirtIO Input keyboard name is 'Vertex VirtIO Keyboard'")

    // Query EV_BITS for EV_KEY (select = 0x11, subsel = 1)
    kbd.WriteConfig(offset: 0, size: 2, value: 0x0111)
    let kbdKeyBitsSize = kbd.ReadConfig(offset: 2, size: 1)
    check(kbdKeyBitsSize >= 16, "VirtIO Keyboard reports at least 16 bytes of key bits")
    // KEY_DOWN is 108: byte 108/8 = 13, bit 108%8 = 4 -> (1<<4) = 0x10
    let byte13 = uint8(kbd.ReadConfig(offset: 8 + 13, size: 1))
    check(byte13 & 0x10 != 0, "VirtIO Keyboard supports KEY_DOWN (108)")

    // 11. The network a card plugs into: net/nat's Gateway, as an
    // ether.Port (net checks the gateway itself: cmd/nat-test there).
    let gw = nat.Gateway()
    check(gw.Config.Gateway.description == "192.168.127.1" && gw.Config.Guest.description == "192.168.127.2",
          "nat.Gateway default network: gateway 192.168.127.1, guest 192.168.127.2")
    check(nat.Config.slirp.Gateway.description == "10.0.2.2" && nat.Config.slirp.Dns.description == "10.0.2.3",
          "nat.Config.slirp is the emulator's network (gateway 10.0.2.2, DNS 10.0.2.3)")
    let cardMac = ether.Mac.Random()
    let ask = wire.Arp(operation: wire.Arp.request, senderMac: cardMac, senderIp: gw.Config.Guest,
                       targetMac: .zero, targetIp: gw.Config.Gateway)
    _ = try? await gw.Send(ether.Frame(destination: .broadcast, source: cardMac, etherType: ether.EtherType.arp,
                                       payload: ask.Encode()).Encode())
    if let reply = try? await gw.Receive(), let f = ether.Frame.Parse(reply), let a = wire.Arp.Parse(f.Payload) {
        check(f.Destination == cardMac && a.Operation == wire.Arp.reply && a.SenderIp == gw.Config.Gateway,
              "nat.Gateway answers the card's ARP for the gateway")
    } else {
        check(false, "nat.Gateway answers the card's ARP for the gateway")
    }

    // 12. ISO 9660 PVD and El Torito checks
    var synthPvd = [uint8](repeating: 0x20, count: 2048)
    synthPvd[0] = 1 // PVD type code
    synthPvd[1] = 0x43 // 'C'
    synthPvd[2] = 0x44 // 'D'
    synthPvd[3] = 0x30 // '0'
    synthPvd[4] = 0x30 // '0'
    synthPvd[5] = 0x31 // '1'
    synthPvd[6] = 1    // Version
    let testVol = [uint8]("DEBIAN_INSTALLER".utf8)
    for idx in 0..<testVol.count {
        synthPvd[40 + idx] = testVol[idx]
    }
    synthPvd[128] = 0x00 // LogicalBlockSize = 2048 (0x0800 LE)
    synthPvd[129] = 0x08

    if let parsedPvd = try? disk.ParseIsoPvd(synthPvd) {
        check(parsedPvd.VolumeId == "DEBIAN_INSTALLER", "ISO PVD Volume ID parsed correctly")
        check(parsedPvd.LogicalBlockSize == 2048, "ISO Logical Block Size is 2048 bytes")
    } else {
        check(false, "ParseIsoPvd failed to parse valid PVD buffer")
    }

    // Live ISO file check (testdata/debian/mini.iso)
    if let isoFile = try? fs.Open(fs.Path("testdata/debian/mini.iso")) {
        defer { try? isoFile.Close() }
        if let info = (try? disk.ReadIsoInfo(from: isoFile)) ?? nil {
            check(info.VolumeId == "ISOIMAGE", "mini.iso Volume ID is 'ISOIMAGE'")
            check(info.LogicalBlockSize == 2048, "mini.iso logical block size is 2048")
            check(info.IsBootable, "mini.iso detected as El Torito bootable")
            check(info.RootLba > 0, "mini.iso Root LBA is non-zero")

            // Test ISO directory reading
            if let rootEntries = try? disk.ReadIsoDirectory(from: isoFile, at: info.RootLba, length: info.RootLength) {
                check(!rootEntries.isEmpty, "mini.iso root directory has entries")
                var hasLinux = false
                var hasInitrd = false
                for e in rootEntries {
                    if e.Name == "linux" { hasLinux = true }
                    if e.Name == "initrd.gz" { hasInitrd = true }
                }
                check(hasLinux, "mini.iso root contains 'linux' kernel")
                check(hasInitrd, "mini.iso root contains 'initrd.gz'")
            } else {
                check(false, "ReadIsoDirectory failed on mini.iso root")
            }

            // Test FindIsoEntry
            if let linuxEntry = (try? disk.FindIsoEntry(from: isoFile, rootLba: info.RootLba, rootLength: info.RootLength, path: "linux")) ?? nil {
                check(linuxEntry.Size > 0, "FindIsoEntry located 'linux' kernel")
                check(!linuxEntry.IsDirectory, "linux entry is a file")
            } else {
                check(false, "FindIsoEntry failed to find 'linux'")
            }

            // Test FindIsoBootFiles
            if let bootFiles = (try? disk.FindIsoBootFiles(from: isoFile, rootLba: info.RootLba, rootLength: info.RootLength)) ?? nil {
                check(bootFiles.KernelPath == "linux", "FindIsoBootFiles identified kernel as 'linux'")
                check(bootFiles.InitrdPath == "initrd.gz", "FindIsoBootFiles identified initrd as 'initrd.gz'")
                check(bootFiles.RecommendedCmdline.contains("console=ttyAMA0"), "FindIsoBootFiles provides recommended cmdline")
            } else {
                check(false, "FindIsoBootFiles failed on mini.iso")
            }
        } else {
            check(false, "ReadIsoInfo failed on mini.iso")
        }
    }

    // Name normalization checks
    check(disk.NormalizeIsoName([uint8]("VMLINUZ.;1".utf8)) == "vmlinuz", "NormalizeIsoName strips ';1' and trailing dot")
    check(disk.NormalizeIsoName([uint8]("INITRD.GZ;1".utf8)) == "initrd.gz", "NormalizeIsoName lowercases extension")

    // Kernel loader and decompression checks
    var synthArm64 = [uint8](repeating: 0, count: 64)
    synthArm64[0x38] = 0x41
    synthArm64[0x39] = 0x52
    synthArm64[0x3a] = 0x4d
    synthArm64[0x3b] = 0x64
    check(boot.DetectKernelFormat(synthArm64) == .rawArm64, "DetectKernelFormat identifies raw ARM64 Image")

    if let unpackedSynth = try? await boot.UnpackKernel(synthArm64) {
        check(unpackedSynth.count == 64, "UnpackKernel passes through raw ARM64 Image")
    } else {
        check(false, "UnpackKernel failed on raw ARM64 Image")
    }

    // A zboot image as Alpine's linux-virt is one: the header at the
    // start of the file ("MZ", "zimg", payload offset and size, "gzip").
    do {
        let payload = gzip.Compress(synthArm64)
        var z = [uint8](repeating: 0, count: 0x40)
        z[0] = 0x4d; z[1] = 0x5a
        z[4] = 0x7a; z[5] = 0x69; z[6] = 0x6d; z[7] = 0x67
        z[8] = 0x40
        z[12] = uint8(payload.count & 0xFF); z[13] = uint8(payload.count >> 8)
        z[0x18] = 0x67; z[0x19] = 0x7a; z[0x1a] = 0x69; z[0x1b] = 0x70
        z += payload
        check(boot.DetectKernelFormat(z) == .efiZboot(compression: "gzip"), "DetectKernelFormat finds a zboot header at the file's start")
        let unpacked = try await boot.UnpackKernel(z)
        check(unpacked == synthArm64, "UnpackKernel unpacks a file-start zboot payload")
    } catch {
        check(false, "zboot at the file's start: \(error)")
    }

    if let debianFile = try? fs.Open(fs.Path("testdata/debian/linux")) {
        defer { try? debianFile.Close() }
        var kHeader = [uint8](repeating: 0, count: 64)
        if (try? debianFile.Read(into: &kHeader, at: 0)) != nil {
            check(boot.DetectKernelFormat(kHeader) == .rawArm64, "Debian kernel header detected as raw ARM64")
        }
    }

    if let vmlinuzFile = try? fs.Open(fs.Path("testdata/ubuntu/casper/vmlinuz")) {
        defer { try? vmlinuzFile.Close() }
        let sz = (try? vmlinuzFile.Metadata().Size) ?? 0
        if sz > 0 {
            var vmlinuzBytes = [uint8](repeating: 0, count: int(sz))
            if (try? vmlinuzFile.Read(into: &vmlinuzBytes, at: 0)) != nil {
                check(boot.DetectKernelFormat(vmlinuzBytes) == .efiZboot(compression: "zstd"), "Ubuntu vmlinuz detected as EFI zboot (zstd)")
                if let decomp = try? await boot.UnpackKernel(vmlinuzBytes) {
                    check(decomp.count > 70000000, "UnpackKernel unpacked Ubuntu vmlinuz (>70MB)")
                    check(boot.DetectKernelFormat(decomp) == .rawArm64, "Unpacked Ubuntu vmlinuz is valid raw ARM64 Image")
                } else {
                    check(false, "UnpackKernel failed on Ubuntu vmlinuz")
                }
            }
        }
    }

    // 16. fw_cfg DMA transfer test
    if let mapping = try? mmap.Anonymous(0x10000), let ptr = mapping.RawPointer {
        let region = device.Region(guest: device.GuestAddress(0), count: 0x10000, host: ptr)
        let mem = device.GuestMemory([region])
        let fwcfg = boot.FwCfg(memory: mem)
        let testPayload = Array("HELLO_FWCFG_DMA".utf8)
        fwcfg.Add(boot.FwCfg.File(name: "opt/test", bytes: testPayload))

        // Descriptor at 0x100: ctl = (0x0020 << 16) | 0x08 | 0x02 (Select file 0x20 and Read)
        // length = 15, address = 0x500
        let ctlVal: uint32 = (0x0020 << 16) | 0x08 | 0x02
        let lenVal: uint32 = 15
        let destAddr: uint64 = 0x500
        var desc = [uint8](repeating: 0, count: 16)
        desc[0] = uint8(ctlVal >> 24)
        desc[1] = uint8((ctlVal >> 16) & 0xff)
        desc[2] = uint8((ctlVal >> 8) & 0xff)
        desc[3] = uint8(ctlVal & 0xff)
        desc[4] = uint8(lenVal >> 24)
        desc[5] = uint8((lenVal >> 16) & 0xff)
        desc[6] = uint8((lenVal >> 8) & 0xff)
        desc[7] = uint8(lenVal & 0xff)
        for b in 0..<8 {
            desc[8 + b] = uint8((destAddr >> (56 - 8 * b)) & 0xff)
        }
        try? mem.Write(device.GuestAddress(0x100), desc)

        // Write descriptor address (in big endian) to fwcfg register 16
        // Host address 0x100 swapped is 0x0001_0000_0000_0000 in little-endian register representation
        var dmaRegVal: uint64 = 0
        var tmpAddr: uint64 = 0x100
        for _ in 0..<8 {
            dmaRegVal = (dmaRegVal << 8) | (tmpAddr & 0xff)
            tmpAddr >>= 8
        }
        fwcfg.Write(offset: 16, size: 8, value: dmaRegVal)

        // Check descriptor ctl was cleared to 0 (completion)
        if let updatedDesc = try? mem.Read(device.GuestAddress(0x100), count: 4) {
            check(updatedDesc[0] == 0 && updatedDesc[1] == 0 && updatedDesc[2] == 0 && updatedDesc[3] == 0, "fw_cfg DMA completed and cleared control")
        } else {
            check(false, "Failed to read updated DMA descriptor")
        }

        // Check payload was written to 0x500
        if let readPayload = try? mem.Read(device.GuestAddress(0x500), count: 15) {
            check(string(decoding: readPayload, as: UTF8.self) == "HELLO_FWCFG_DMA", "fw_cfg DMA read transferred file contents to guest memory")
        } else {
            check(false, "Failed to read DMA destination buffer")
        }
    }

    // 17. PCI Root Complex & BAR sizing test
    final class MockPciFunction: pci.Function {
        let Config: pci.ConfigSpace
        let Bars: [pci.Bar]

        init(bars: [pci.Bar]) {
            self.Config = pci.ConfigSpace(vendor: 0x1234, device: 0x5678, classCode: pci.ClassCode.other, revision: 1)
            self.Bars = bars
        }

        func ReadBar(_ bar: int, offset: uint64, size: uint8) -> uint64 { 0 }
        func WriteBar(_ bar: int, offset: uint64, size: uint8, value: uint64) {}
    }

    let pciLayout = pci.Layout(
        ecam: device.Range(base: 0x1000_0000, count: 0x1000_0000),
        mmio32: device.Range(base: 0x2000_0000, count: 0x2000_0000),
        mmio64: device.Range(base: 0x1_0000_0000, count: 0x1_0000_0000),
        irqBase: 16
    )
    let pciRoot = pci.Root(pciLayout)
    let mockDev = MockPciFunction(bars: [
        pci.Bar(index: 0, size: 0x4000, kind: .memory64, prefetchable: false)
    ])
    if let slot = try? pciRoot.Attach(mockDev) {
        check(slot == 1, "PCI device attached at slot 1")
        let initialBar0 = mockDev.Config.Read(offset: 0x10, size: 4)
        check((initialBar0 & 0x4) != 0, "PCI BAR 0 reports 64-bit memory kind")

        // Perform BAR sizing probe: write 0xffff_ffff to BAR 0 register in ECAM (bus 0, dev 1, fn 0, reg 0x10)
        let ecamOffset: uint64 = (1 << 15) | 0x10
        pciRoot.Write(offset: ecamOffset, size: 4, value: 0xffff_ffff)

        let probedBar0 = pciRoot.Read(offset: ecamOffset, size: 4)
        check(probedBar0 == 0xffff_c004, "PCI BAR 0 sizing probe returns size mask 0xffff_c004")

        // Program assigned address 0x2000_0000 into BAR 0
        pciRoot.Write(offset: ecamOffset, size: 4, value: 0x2000_0000)
        let readBackBar0 = pciRoot.Read(offset: ecamOffset, size: 4)
        check((readBackBar0 & ~uint64(0xf)) == 0x2000_0000, "PCI BAR 0 readback returns programmed address")
    } else {
        check(false, "Failed to attach mock PCI device")
    }

    // 18. ACPI ARM64 Payload & TableLoader checks
    let acpiCfg = acpi.Arm64Config(vcpus: 4, virtioCount: 2)
    let acpiPayload = acpi.BuildArm64(acpiCfg)
    check(acpiPayload.Tables.count > 0, "ACPI Tables blob generated")
    check(acpiPayload.Rsdp.count == 36, "ACPI RSDP is 36 bytes")
    check(acpiPayload.Loader.count > 0 && acpiPayload.Loader.count % 128 == 0, "ACPI TableLoader produces 128-byte aligned commands")
    let rsdpSig = string(decoding: acpiPayload.Rsdp[0..<8], as: UTF8.self)
    check(rsdpSig == "RSD PTR ", "ACPI RSDP magic signature matches 'RSD PTR '")
    let dsdtSig = string(decoding: acpiPayload.Tables[0..<4], as: UTF8.self)
    check(dsdtSig == "DSDT", "First ACPI table is DSDT")

    // 19. Windows ISO Detection checks
    let winIsoPath = "/Users/galaxy/Desktop/Windows11_Client_arm64_en-us_26300_9457.iso"
    if let winIso = (try? windows.DetectIso(winIsoPath)) ?? nil {
        check(winIso.IsArm64, "Windows ISO detected as ARM64")
        check(winIso.VolumeId.contains("CCCOMA"), "Windows ISO VolumeId contains CCCOMA")
        check(winIso.Edition.contains("Windows"), "Windows ISO Edition identifies as Windows")
    } else {
        check(false, "Failed to detect Windows ISO at \(winIsoPath)")
    }

    // 20. Windows 11 LabConfig / Unattended checks
    let autoXml = windows.GenerateAutoUnattendXml()
    check(autoXml.contains("BypassTPMCheck"), "AutoUnattend XML contains BypassTPMCheck")
    check(autoXml.contains("BypassSecureBootCheck"), "AutoUnattend XML contains BypassSecureBootCheck")

    // 21. The devices Windows guests get, and the ACPI they read.
    checkPci()
    await checkNvme()
    await checkNvmeMsix()
    await checkUsbStorage()
    await checkXhci()
    checkAcpiFixes()
    checkAcpiTpm()
    await checkTpm()
    checkFirmware()

    // 22. Android 5–7 on the emulator's devices.
    checkAndroid()
    checkGoldfishPipe()
    checkGfxstream()

    if failures == 0 {
        print("ALL VM CHECKS PASSED")
        return 0
    }
    print("\(failures) FAILED")
    return 1
}
