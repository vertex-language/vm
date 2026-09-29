// cmd/check: offline verification of device models, boot headers, queues, and FDT/ACPI.
package main

import (
    "encoding/fdt"
    "io"
    "sync"
    "vm"
    "vm/boot"
    "vm/chipset"
    "vm/device"
    "vm/virtio"
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

func main() -> int32 {
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

    if failures == 0 {
        print("ALL VM CHECKS PASSED")
        return 0
    }
    print("\(failures) FAILED")
    return 1
}
