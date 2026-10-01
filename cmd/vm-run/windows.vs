import (
    "fs"
    "ui/window"
    "vm"
    "vm/disk"
    "vm/windows"
)

/// What `vm-run --iso <windows.iso>` was given beyond the ISO.
struct WindowsOptions {
    var Iso: string
    var Disk: string? = nil
    var DiskSize: uint64 = 64 << 30
    var Firmware: string? = nil
    var Vars: string? = nil
    var MemoryMiB: int = 4096
    var Cpus: int = 4
    var Screenshot: string? = nil
    var TimeoutSec: int? = nil
    var Display = true
}

/// The HID usage (page 7) of a host key, for the guest's USB keyboard.
func hidUsageFor(_ code: window.KeyCode) -> uint8? {
    let raw = code.rawValue
    if raw >= window.KeyCode.a.rawValue && raw <= window.KeyCode.z.rawValue {
        return uint8(0x04 + raw - window.KeyCode.a.rawValue)
    }
    if raw >= window.KeyCode.digit1.rawValue && raw <= window.KeyCode.digit9.rawValue {
        return uint8(0x1e + raw - window.KeyCode.digit1.rawValue)
    }
    if raw >= window.KeyCode.f1.rawValue && raw <= window.KeyCode.f12.rawValue {
        return uint8(0x3a + raw - window.KeyCode.f1.rawValue)
    }
    switch code {
    case .digit0: return 0x27
    case .enter: return 0x28
    case .escape: return 0x29
    case .backspace: return 0x2a
    case .tab: return 0x2b
    case .space: return 0x2c
    case .minus: return 0x2d
    case .equal: return 0x2e
    case .bracketLeft: return 0x2f
    case .bracketRight: return 0x30
    case .backslash: return 0x31
    case .semicolon: return 0x33
    case .quote: return 0x34
    case .backquote: return 0x35
    case .comma: return 0x36
    case .period: return 0x37
    case .slash: return 0x38
    case .capsLock: return 0x39
    case .home: return 0x4a
    case .pageUp: return 0x4b
    case .delete: return 0x4c
    case .end: return 0x4d
    case .pageDown: return 0x4e
    case .arrowRight: return 0x4f
    case .arrowLeft: return 0x50
    case .arrowDown: return 0x51
    case .arrowUp: return 0x52
    case .controlLeft: return 0xe0
    case .shiftLeft: return 0xe1
    case .altLeft: return 0xe2
    case .metaLeft: return 0xe3
    case .controlRight: return 0xe4
    case .shiftRight: return 0xe5
    case .altRight: return 0xe6
    case .metaRight: return 0xe7
    default: return nil
    }
}

/// Where a disk's EFI variables are kept between runs: beside it.
func varsPath(for diskPath: string) -> string {
    diskPath + ".efivars"
}

/// Boots a Windows ARM64 installer ISO, or the Windows on `Disk`, under
/// UEFI: the ISO as a USB CD-ROM, the disk as NVMe, the keyboard and mouse
/// as USB HID, the screen through ramfb.
func runWindows(_ o: WindowsOptions) async throws {
    let diskPath = o.Disk ?? "windows.raw"
    let target: any disk.Image
    if (try? fs.Open(fs.Path(diskPath))) != nil {
        target = try await vm.OpenDisk(fs.Path(diskPath))
    } else {
        print("[Windows] Creating \(o.DiskSize >> 30) GiB disk: \(diskPath)")
        target = try disk.CreateRaw(fs.Path(diskPath), size: o.DiskSize)
    }
    // Nothing installed yet: no partition table in sector 0 or 1.
    var head = [uint8](repeating: 0, count: 1024)
    try? await target.ReadAt(0, into: &head)
    let blank = head.allSatisfy { $0 == 0 }

    // EFI variables saved from the last run win over the template.
    var vars = o.Vars
    let saved = varsPath(for: diskPath)
    if vars == nil && (try? fs.Open(fs.Path(saved))) != nil {
        vars = saved
    }
    var cfg = try await windows.ConfigureVm(
        isoPath: o.Iso,
        vcpus: o.Cpus,
        memoryMiB: o.MemoryMiB,
        targetDisk: target,
        customCodePath: o.Firmware,
        customVarsPath: vars
    )
    if !o.Display && o.Screenshot == nil {
        cfg.Display = .none
    }

    print("=== Launching Windows (ARM64, UEFI) ===")
    print("ISO:        \(o.Iso) (USB CD-ROM)")
    print("Disk:       \(diskPath) (NVMe, \(target.Size >> 30) GiB)")
    print("EFI vars:   \(saved)")
    print("Memory:     \(o.MemoryMiB) MiB")
    print("vCPUs:      \(max(2, o.Cpus))")
    print("Network:    none (Windows has no inbox driver for VirtIO net)")
    print("---------------------------------")

    let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
    defer { machine.Close() }
    try machine.Start()

    // Keeps the variable store, so the boot entries Setup writes stay.
    func saveVars() {
        guard let bytes = machine.Pflash?.Bytes, let f = try? fs.Create(fs.Path(saved)) else { return }
        try? f.Write(bytes)
        try? f.Close()
    }

    if blank {
        // The installer's boot loader asks for a key before it boots from
        // the CD, and with none falls through to the empty disk.
        print("[Windows] Blank disk: pressing a key for the installer's \"Press any key to boot from CD\"")
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // past the firmware's own prompt
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                machine.UsbKeyboard?.Key(0x2c, pressed: true)
                machine.UsbKeyboard?.Key(0x2c, pressed: false)
            }
        }
    }

    if let ts = o.TimeoutSec {
        Task {
            try? await Task.sleep(nanoseconds: uint64(ts) * 1_000_000_000)
            if let sp = o.Screenshot {
                try? machine.Framebuffer?.SavePNG(to: fs.Path(sp))
                print("[Host] Saved screenshot to: \(sp)")
            }
            machine.Terminate()
        }
    }

    if !o.Display {
        let status = try await machine.Wait()
        saveVars()
        print("\nVM exited: \(status)")
        return
    }

    var options = window.Options()
    options.Resizable = true
    options.MinSize = window.Size(640, 480)
    let w = try window.Create(title: "Vertex VM — Windows (ARM64)", size: window.Size(1024, 768), options: options)
    let surface = w.Surface()
    surface.SetScaling(.aspectFit)
    w.RequestFrame()
    var currentSize = window.Size(1024, 768)

    // The guest picks its mode through ramfb; the window shows whatever
    // it is now.
    func guestSize() -> (float32, float32) {
        guard let fb = machine.Framebuffer, fb.Configured else { return (1024, 768) }
        return (float32(fb.Width), float32(fb.Height))
    }

    func pointerFraction(_ pos: window.Point) -> (float64, float64)? {
        let (fbW, fbH) = guestSize()
        let scale = min(currentSize.Width / fbW, currentSize.Height / fbH)
        let dispW = fbW * scale
        let dispH = fbH * scale
        let relX = pos.X - (currentSize.Width - dispW) * 0.5
        let relY = pos.Y - (currentSize.Height - dispH) * 0.5
        if relX < 0 || relX >= dispW || relY < 0 || relY >= dispH {
            return nil
        }
        return (float64(relX / dispW), float64(relY / dispH))
    }

    func buttonIndex(_ b: window.PointerButton) -> int {
        switch b {
        case .primary: return 0
        case .secondary: return 1
        case .middle: return 2
        case .other: return 0
        }
    }

    func quit(_ how: string) async {
        w.Close()
        if let sp = o.Screenshot {
            try? machine.Framebuffer?.SavePNG(to: fs.Path(sp))
        }
        machine.Terminate()
        _ = try? await machine.Wait()
        saveVars()
        print("\nVM closed from \(how).")
    }

    print("[Host GUI] Window open. Controls: [Cmd+S] screenshot, [Cmd+Q/W] exit; Cmd alone is the Windows key.")

    while let event = await w.WaitEvent() {
        switch event {
        case .closeRequested:
            await quit("window")
            return

        case .resized(let size):
            currentSize = size
            w.RequestFrame()

        case .pointerMoved(let ptr):
            if let (x, y) = pointerFraction(ptr.Position) {
                machine.UsbTablet?.Move(x: x, y: y)
            }

        case .pointerDown(let ptr, let btn):
            if let (x, y) = pointerFraction(ptr.Position) {
                machine.UsbTablet?.Move(x: x, y: y)
            }
            machine.UsbTablet?.Button(buttonIndex(btn), pressed: true)

        case .pointerUp(let ptr, let btn):
            if let (x, y) = pointerFraction(ptr.Position) {
                machine.UsbTablet?.Move(x: x, y: y)
            }
            machine.UsbTablet?.Button(buttonIndex(btn), pressed: false)

        case .scrolled(let s):
            let lines = s.Precise ? s.Delta.Y / 20 : s.Delta.Y
            let clicks = int8(max(-127, min(127, lines.rounded())))
            if clicks != 0 {
                machine.UsbTablet?.Wheel(clicks)
            }

        case .keyDown(let k):
            if k.Modifiers.Meta && (k.Code == .q || k.Code == .w) {
                await quit("keyboard shortcut")
                return
            }
            if k.Modifiers.Meta && k.Code == .s {
                let path = fs.Path(o.Screenshot ?? "screenshot.png")
                if (try? machine.Framebuffer?.SavePNG(to: path)) != nil {
                    print("\n[Host] Saved screenshot to: \(path.Value)")
                }
                continue
            }
            if !k.Repeat, let usage = hidUsageFor(k.Code) {
                machine.UsbKeyboard?.Key(usage, pressed: true)
            }

        case .keyUp(let k):
            if let usage = hidUsageFor(k.Code) {
                machine.UsbKeyboard?.Key(usage, pressed: false)
            }

        case .frame(_):
            let (fbW, fbH) = guestSize()
            if let snap = try? machine.Framebuffer?.Snapshot(), !snap.isEmpty {
                try? surface.Present(snap, size: window.PixelSize(int32(fbW), int32(fbH)))
            }
            w.RequestFrame()

        default:
            break
        }
    }
}
