import (
    "vm/boot"
    "vm/chipset"
    "vm/device"
    "vm/display"
    "vm/virtio"
)

/// What Android 5–7's emulator kernels need: legacy VirtIO MMIO, the
/// goldfish screen, input and battery, and knowing an old kernel when
/// one is given.
func checkAndroid() {
    // Linux before 4.0 knows VirtIO MMIO version 1 only.
    let mem = try! scratchMemory(base: 0x4000_0000, size: 1 << 20)
    let irq = device.RecordingIrq()
    let t = virtio.MmioTransport(virtio.Rng(), memory: mem.0, irq: irq, legacy: true)
    check(t.Read(offset: 0x004, size: 4) == 1, "legacy VirtIO MMIO: version 1")
    t.Write(offset: 0x014, size: 4, value: 1)
    check(t.Read(offset: 0x010, size: 4) == 0, "legacy VirtIO MMIO: no feature bits past 31 (no VERSION_1)")
    t.Write(offset: 0x028, size: 4, value: 4096)        // GuestPageSize
    t.Write(offset: 0x030, size: 4, value: 0)           // QueueSel
    t.Write(offset: 0x038, size: 4, value: 64)          // QueueNum
    t.Write(offset: 0x03c, size: 4, value: 4096)        // QueueAlign
    t.Write(offset: 0x040, size: 4, value: 0x4_0001)    // QueuePFN: 0x4000_1000
    check(t.Read(offset: 0x040, size: 4) == 0x4_0001, "legacy VirtIO MMIO: QueuePFN reads back")
    // Descriptors at the page, the available ring 16·64 bytes on, the used
    // ring at the next 4 KiB after the available ring's 6 + 2·64 bytes.
    t.Write(offset: 0x070, size: 4, value: 1 | 2 | 4)   // ACKNOWLEDGE | DRIVER | DRIVER_OK
    check(t.Read(offset: 0x070, size: 4) == 7, "legacy VirtIO MMIO: DRIVER_OK without FEATURES_OK")

    // The kernel's own version string.
    var k = [uint8](repeating: 0, count: 4096)
    let banner = [uint8]("Linux version 3.18.91+ (android-build@abfarm368)".utf8)
    for i in 0..<banner.count { k[100 + i] = banner[i] }
    if let (major, minor) = boot.LinuxVersion(k) {
        check(major == 3 && minor == 18, "LinuxVersion reads 3.18 from the banner")
    } else {
        check(false, "LinuxVersion reads 3.18 from the banner")
    }
    check(boot.LinuxVersion([uint8](repeating: 0x41, count: 4096)) == nil, "LinuxVersion: no banner, no version")

    // goldfish-fb: the size, then BASE_UPDATE_DONE once the base is set.
    let fbIrq = device.RecordingIrq()
    let fb = display.GoldfishFb(memory: mem.0, irq: fbIrq, width: 320, height: 480)
    check(fb.Read(offset: 0x00, size: 4) == 320 && fb.Read(offset: 0x04, size: 4) == 480, "goldfish-fb: width and height")
    fb.Write(offset: 0x0c, size: 4, value: 2)           // INT_ENABLE: BASE_UPDATE_DONE
    fb.Write(offset: 0x10, size: 4, value: 0x4000_0000) // SET_BASE
    check(fbIrq.Level, "goldfish-fb: SET_BASE raises BASE_UPDATE_DONE")
    check(fb.Read(offset: 0x08, size: 4) == 2 && !fbIrq.Level, "goldfish-fb: reading INT_STATUS clears it")
    check(fb.Framebuffer.Configured && fb.Framebuffer.Address.Value == 0x4000_0000 && fb.Framebuffer.Stride == 640,
          "goldfish-fb: the screen scans out from the base, RGB565")
    // One white and one pure-red RGB565 pixel come out as RGBA.
    try? mem.0.Write(device.GuestAddress(0x4000_0000), [0xff, 0xff, 0x00, 0xf8])
    if let px = try? fb.Framebuffer.Snapshot(), px.count == 320 * 480 * 4 {
        check(px[0] == 255 && px[1] == 255 && px[2] == 255 && px[4] == 255 && px[5] == 0 && px[6] == 0,
              "goldfish-fb: RGB565 widens to RGBA")
    } else {
        check(false, "goldfish-fb: RGB565 widens to RGBA")
    }

    // goldfish-events: named qwerty2, keys and ABS_X/ABS_Y, events in order.
    let evIrq = device.RecordingIrq()
    let ev = chipset.GoldfishEvents(irq: evIrq, width: 320, height: 480)
    ev.Write(offset: 0x00, size: 4, value: 0)           // PAGE_NAME
    let n = int(ev.Read(offset: 0x04, size: 4))
    var nameBytes: [uint8] = []
    for i in 0..<n { nameBytes.append(uint8(ev.Read(offset: 0x08 + uint64(i), size: 1))) }
    let name = string(decoding: nameBytes, as: UTF8.self)
    check(name == "qwerty2", "goldfish-events: called qwerty2 (\(name))")
    ev.Write(offset: 0x00, size: 4, value: 0x1_0000)    // PAGE_EVBITS | EV_SYN
    check(ev.Read(offset: 0x08, size: 1) == 0b1011, "goldfish-events: EV_SYN, EV_KEY and EV_ABS")
    ev.Write(offset: 0x00, size: 4, value: 0x2_0003)    // PAGE_ABSDATA
    check(ev.Read(offset: 0x04, size: 4) == 32 && ev.Read(offset: 0x0c, size: 4) == 319 && ev.Read(offset: 0x1c, size: 4) == 479,
          "goldfish-events: ABS_X 0…319, ABS_Y 0…479")
    ev.Touch(x: 10, y: 20, down: true)
    check(evIrq.Level, "goldfish-events: a touch raises the interrupt")
    var words: [uint64] = []
    while evIrq.Level { words.append(ev.Read(offset: 0x00, size: 4)) }
    check(words == [3, 0, 10, 3, 1, 20, 1, 0x14a, 1, 0, 0, 0], "goldfish-events: ABS_X, ABS_Y, BTN_TOUCH down, SYN_REPORT (\(words))")

    // goldfish-battery: present, full, on mains.
    let bat = chipset.GoldfishBattery()
    check(bat.Read(offset: 0x14, size: 4) == 1 && bat.Read(offset: 0x18, size: 4) == 100 && bat.Read(offset: 0x08, size: 4) == 1,
          "goldfish-battery: present, 100%, AC online")
    _ = mem.1
}
