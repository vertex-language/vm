import (
    "fs"
    "io"
    "os/process"
    "sync"
    "time"
    "ui/window"
    "vm"
    "vm/boot"
    "vm/chipset"
    "vm/device"
    "vm/disk"
    "vm/hypervisor"
)

func printUsage() {
    print("""
Usage: vm-run [options]

Options:
  --kernel <path>    Path to Linux ARM64 kernel Image or vmlinuz (supports raw, gzip, EFI zboot)
  --initrd <path>    Path to initramfs image (default: testdata/initramfs-virt)
  --cmdline <str>    Kernel command line arguments
  --memory <MB>      Guest physical memory in MB (default: 512)
  --cpus <N>         Number of virtual CPUs (default: 1)
  --disk <path>      Path to disk image (raw/qcow2) to attach as VirtIO block device
  --cdrom, --iso <p> Path to ISO optical disc image to attach as read-only installer media
  --display, --gui   Open graphical window for guest framebuffer
  --width <px>       Guest framebuffer width (default: 1024)
  --height <px>      Guest framebuffer height (default: 768)
  --screenshot <path> Save guest framebuffer snapshot to PNG file
  --timeout <sec>    Automatically terminate VM after N seconds
  --net              Enable user-space NAT networking (default: enabled)
  --no-net           Disable networking
  --help, -h         Show this help message
""")
}

func evdevCodeFor(_ code: window.KeyCode) -> uint16? {
    switch code {
    case .escape: return 1       // KEY_ESC
    case .digit1: return 2       // KEY_1
    case .digit2: return 3       // KEY_2
    case .digit3: return 4       // KEY_3
    case .digit4: return 5       // KEY_4
    case .digit5: return 6       // KEY_5
    case .digit6: return 7       // KEY_6
    case .digit7: return 8       // KEY_7
    case .digit8: return 9       // KEY_8
    case .digit9: return 10      // KEY_9
    case .digit0: return 11      // KEY_0
    case .minus: return 12       // KEY_MINUS
    case .equal: return 13       // KEY_EQUAL
    case .backspace: return 14   // KEY_BACKSPACE
    case .tab: return 15         // KEY_TAB
    case .q: return 16           // KEY_Q
    case .w: return 17           // KEY_W
    case .e: return 18           // KEY_E
    case .r: return 19           // KEY_R
    case .t: return 20           // KEY_T
    case .y: return 21           // KEY_Y
    case .u: return 22           // KEY_U
    case .i: return 23           // KEY_I
    case .o: return 24           // KEY_O
    case .p: return 25           // KEY_P
    case .bracketLeft: return 26 // KEY_LEFTBRACE
    case .bracketRight: return 27// KEY_RIGHTBRACE
    case .enter: return 28       // KEY_ENTER
    case .controlLeft: return 29 // KEY_LEFTCTRL
    case .a: return 30           // KEY_A
    case .s: return 31           // KEY_S
    case .d: return 32           // KEY_D
    case .f: return 33           // KEY_F
    case .g: return 34           // KEY_G
    case .h: return 35           // KEY_H
    case .j: return 36           // KEY_J
    case .k: return 37           // KEY_K
    case .l: return 38           // KEY_L
    case .semicolon: return 39   // KEY_SEMICOLON
    case .quote: return 40       // KEY_APOSTROPHE
    case .backquote: return 41   // KEY_GRAVE
    case .shiftLeft: return 42   // KEY_LEFTSHIFT
    case .backslash: return 43   // KEY_BACKSLASH
    case .z: return 44           // KEY_Z
    case .x: return 45           // KEY_X
    case .c: return 46           // KEY_C
    case .v: return 47           // KEY_V
    case .b: return 48           // KEY_B
    case .n: return 49           // KEY_N
    case .m: return 50           // KEY_M
    case .comma: return 51       // KEY_COMMA
    case .period: return 52      // KEY_DOT
    case .slash: return 53       // KEY_SLASH
    case .shiftRight: return 54  // KEY_RIGHTSHIFT
    case .altLeft: return 56     // KEY_LEFTALT
    case .space: return 57       // KEY_SPACE
    case .capsLock: return 58    // KEY_CAPSLOCK
    case .f1: return 59          // KEY_F1
    case .f2: return 60          // KEY_F2
    case .f3: return 61          // KEY_F3
    case .f4: return 62          // KEY_F4
    case .f5: return 63          // KEY_F5
    case .f6: return 64          // KEY_F6
    case .f7: return 65          // KEY_F7
    case .f8: return 66          // KEY_F8
    case .f9: return 67          // KEY_F9
    case .f10: return 68         // KEY_F10
    case .f11: return 87         // KEY_F11
    case .f12: return 88         // KEY_F12
    case .controlRight: return 97// KEY_RIGHTCTRL
    case .altRight: return 100   // KEY_RIGHTALT
    case .home: return 102       // KEY_HOME
    case .arrowUp: return 103    // KEY_UP
    case .pageUp: return 104     // KEY_PAGEUP
    case .arrowLeft: return 105  // KEY_LEFT
    case .arrowRight: return 106 // KEY_RIGHT
    case .end: return 107        // KEY_END
    case .arrowDown: return 108  // KEY_DOWN
    case .pageDown: return 109   // KEY_PAGEDOWN
    case .delete: return 111     // KEY_DELETE
    case .metaLeft: return 125   // KEY_LEFTMETA
    case .metaRight: return 126  // KEY_RIGHTMETA
    default: return nil
    }
}

public func main() async throws {
    let args = process.Args

    var kernelPath = "testdata/Image"
    var initrdPath: string? = "testdata/initramfs-virt"
    var cmdline = "console=ttyAMA0 earlycon=pl011,0x09000000 reboot=k panic=-1"
    var memoryMb: uint64 = 512
    var cpus: int = 1
    var diskPath: string? = nil
    var cdromPath: string? = nil
    var enableDisplay = false
    var displayWidth: int = 1024
    var displayHeight: int = 768
    var screenshotPath: string? = nil
    var screenshotDelaySec: int = 5
    var timeoutSec: int? = nil
    var enableNet = true
    var guestCommand: string? = nil
    var commandDelayMs: int = 5600
    var explicitKernel = false
    var explicitInitrd = false
    var explicitCmdline = false

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--help", "-h":
            printUsage()
            return
        case "--timeout":
            if i + 1 < args.count {
                if let t = int(args[i + 1]), t > 0 {
                    timeoutSec = t
                }
                i += 1
            }
        case "--net":
            enableNet = true
        case "--no-net":
            enableNet = false
        case "--command":
            if i + 1 < args.count {
                guestCommand = args[i + 1]
                i += 1
            }
        case "--command-delay":
            if i + 1 < args.count {
                if let d = int(args[i + 1]), d >= 0 {
                    commandDelayMs = d * 1000
                }
                i += 1
            }
        case "--command-delay-ms":
            if i + 1 < args.count {
                if let d = int(args[i + 1]), d >= 0 {
                    commandDelayMs = d
                }
                i += 1
            }
        case "--display", "--gui":
            enableDisplay = true
        case "--width":
            if i + 1 < args.count {
                if let w = int(args[i + 1]), w > 0 {
                    displayWidth = w
                }
                i += 1
            }
        case "--height":
            if i + 1 < args.count {
                if let h = int(args[i + 1]), h > 0 {
                    displayHeight = h
                }
                i += 1
            }
        case "--screenshot":
            if i + 1 < args.count {
                screenshotPath = args[i + 1]
                i += 1
            }
        case "--screenshot-delay":
            if i + 1 < args.count {
                if let d = int(args[i + 1]), d >= 0 {
                    screenshotDelaySec = d
                }
                i += 1
            }
        case "--kernel":
            if i + 1 < args.count {
                kernelPath = args[i + 1]
                explicitKernel = true
                i += 1
            }
        case "--initrd":
            if i + 1 < args.count {
                initrdPath = args[i + 1]
                explicitInitrd = true
                i += 1
            }
        case "--cmdline":
            if i + 1 < args.count {
                cmdline = args[i + 1]
                explicitCmdline = true
                i += 1
            }
        case "--memory":
            if i + 1 < args.count {
                if let m = int(args[i + 1]), m > 0 {
                    memoryMb = uint64(m)
                }
                i += 1
            }
        case "--cpus":
            if i + 1 < args.count {
                if let c = int(args[i + 1]), c > 0 {
                    cpus = c
                }
                i += 1
            }
        case "--disk":
            if i + 1 < args.count {
                diskPath = args[i + 1]
                i += 1
            }
        case "--cdrom", "--iso":
            if i + 1 < args.count {
                cdromPath = args[i + 1]
                i += 1
            }
        default:
            print("Unknown argument: \(arg)")
            printUsage()
            return
        }
        i += 1
    }

func readFileBytes(_ path: fs.Path) throws -> [uint8] {
    let file = try fs.Open(path)
    defer { try? file.Close() }
    let totalSize = try file.Metadata().Size
    if totalSize == 0 { return [] }
    var result = [uint8](repeating: 0, count: int(totalSize))
    var offset: int64 = 0
    let chunkSize = 4 * 1024 * 1024
    var chunk = [uint8](repeating: 0, count: chunkSize)
    while offset < totalSize {
        let n = try file.Read(into: &chunk, at: offset)
        if n <= 0 { break }
        let toCopy = min(n, int(totalSize - offset))
        for j in 0..<toCopy {
            result[int(offset) + j] = chunk[j]
        }
        offset += int64(toCopy)
    }
    return result
}

    // If an ISO/CD-ROM was attached but no explicit kernel was given, attempt auto-boot
    var kernelBytes: [uint8]? = nil
    var initrdBytes: [uint8]? = nil
    var kernelDisplayName = kernelPath
    var initrdDisplayName = initrdPath

    if let cp = cdromPath, !explicitKernel {
        if let isoFile = try? fs.Open(fs.Path(cp)) {
            defer { try? isoFile.Close() }
            if let info = try? disk.ReadIsoInfo(from: isoFile),
               let bootFiles = try? disk.FindIsoBootFiles(from: isoFile, rootLba: info.RootLba, rootLength: info.RootLength) {
                print("[ISO Auto-Boot] Detected bootable installer on \(cp):")
                print("  Volume:     \(info.VolumeId)")
                print("  Kernel:     \(bootFiles.KernelPath) (\(bootFiles.Kernel.Size) bytes)")
                if let rd = bootFiles.Initrd {
                    print("  Initrd:     \(bootFiles.InitrdPath ?? "") (\(rd.Size) bytes)")
                }

                var kCandidate: [uint8]? = nil
                // If local decompressed image exists for this distribution kernel, prefer it for fast startup
                if bootFiles.KernelPath == "casper/vmlinuz" && (try? fs.Open(fs.Path("testdata/ubuntu/casper/Image"))) != nil {
                    print("  Using cached decompressed kernel: testdata/ubuntu/casper/Image")
                    kCandidate = try? readFileBytes(fs.Path("testdata/ubuntu/casper/Image"))
                    kernelDisplayName = "\(cp):/\(bootFiles.KernelPath) (cached Image)"
                } else {
                    print("  Reading kernel directly from ISO...")
                    kCandidate = try? disk.ReadIsoFile(from: isoFile, entry: bootFiles.Kernel)
                    kernelDisplayName = "\(cp):/\(bootFiles.KernelPath)"
                }

                if let kb = kCandidate {
                    kernelBytes = kb
                    if !explicitInitrd, let rd = bootFiles.Initrd {
                        print("  Reading initrd directly from ISO...")
                        initrdBytes = try? disk.ReadIsoFile(from: isoFile, entry: rd)
                        initrdDisplayName = "\(cp):/\(bootFiles.InitrdPath ?? "")"
                    }
                    if !explicitCmdline {
                        cmdline = bootFiles.RecommendedCmdline
                    }
                    if memoryMb <= 512 && bootFiles.KernelPath.starts(with: "casper") {
                        memoryMb = 4096
                        cpus = max(cpus, 4)
                    }
                }
            }
        }
    }

    let rawKernel: [uint8]
    if let kb = kernelBytes {
        rawKernel = kb
    } else {
        let kPath = fs.Path(kernelPath)
        guard let k = try? readFileBytes(kPath) else {
            print("Error: Could not open kernel at: \(kernelPath)")
            printUsage()
            return
        }
        rawKernel = k
    }

    let kFmt = boot.DetectKernelFormat(rawKernel)
    if kFmt != .rawArm64 {
        print("[Kernel] Detected \(kFmt), unpacking...")
    }
    let kernel: [uint8]
    do {
        kernel = try await boot.UnpackKernel(rawKernel)
    } catch {
        print("Error: Failed to unpack kernel: \(error)")
        return
    }

    var initrd: [uint8]? = initrdBytes
    if initrd == nil, let ip = initrdPath {
        let iPath = fs.Path(ip)
        do {
            initrd = try readFileBytes(iPath)
        } catch {
            print("Warning: Failed to read initrd at \(ip): \(error)")
        }
    }

    var cfg = vm.Config(cpus: cpus, memory: memoryMb << 20)
    cfg.Boot = .linux(kernel: kernel, initrd: initrd, cmdline: cmdline)
    if enableDisplay || screenshotPath != nil {
        cfg.Display = .custom(width: displayWidth, height: displayHeight)
    }
    if enableNet {
        cfg.Network.append(.nat())
    }

    // Optional disk
    if let dp = diskPath {
        do {
            let img = try await vm.OpenDisk(fs.Path(dp))
            cfg.Storage.append(.disk(img))
        } catch {
            print("Warning: Failed to open disk at \(dp): \(error)")
        }
    }

    // Optional CD-ROM / ISO installer media
    if let cp = cdromPath {
        do {
            let img = try await vm.OpenDisk(fs.Path(cp), readOnly: true)
            cfg.Storage.append(.installer(img))
        } catch {
            print("Warning: Failed to open CD-ROM/ISO at \(cp): \(error)")
        }
    }

    print("=== Launching Virtual Machine ===")
    print("Kernel:     \(kernelDisplayName) (\(kernel.count) bytes, \(kFmt))")
    if let rd = initrd {
        print("Initrd:     \(initrdDisplayName ?? "unnamed") (\(rd.count) bytes)")
    }
    if let cp = cdromPath {
        print("CD-ROM/ISO: \(cp)")
    }
    print("Memory:     \(memoryMb) MiB")
    print("vCPUs:      \(cpus)")
    print("Network:    \(enableNet ? "User-space NAT (192.168.127.1, DHCP, DNS)" : "disabled")")
    print("Display:    \(cfg.Display.Enabled ? "\(cfg.Display.Width)x\(cfg.Display.Height) graphical framebuffer" : "none (headless)")")
    if let sp = screenshotPath {
        print("Screenshot: \(sp)")
    }
    print("Cmdline:    \(cmdline)")
    print("---------------------------------")

    let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
    defer { machine.Close() }

    // Start background thread forwarding stdin to UART RX
    _ = sync.Thread.spawn {
        var stdin = process.Stdin
        var buf = [uint8](repeating: 0, count: 256)
        while true {
            guard let n = try? stdin.Read(into: &buf), n > 0 else { break }
            var bytes = [uint8]()
            for b in buf[0..<n] {
                if b == 10 { // translate LF to CR for terminal enter
                    bytes.append(13)
                } else {
                    bytes.append(b)
                }
            }
            machine.ConsoleUart?.Feed(bytes)
        }
    }

    try machine.Start()

    // If guest command specified, feed it after delay
    if let cmd = guestCommand {
        Task {
            try? await time.Sleep(.Milliseconds(int64(commandDelayMs)))
            var cmdBytes = [uint8](cmd.utf8)
            cmdBytes.append(13) // carriage return
            machine.ConsoleUart?.Feed(cmdBytes)
        }
    }

    // If screenshot requested, schedule capture after delay
    if let sp = screenshotPath {
        Task {
            try? await time.Sleep(.Milliseconds(int64(screenshotDelaySec * 1000)))
            if let fb = machine.Framebuffer {
                do {
                    try fb.SavePNG(to: fs.Path(sp))
                    print("\n[Host] Saved screenshot to: \(sp)")
                } catch {
                    print("\n[Host] Failed to save screenshot: \(error)")
                }
            }
        }
    }

    // If timeout specified, automatically terminate machine
    if let ts = timeoutSec {
        Task {
            try? await time.Sleep(.Milliseconds(int64(ts * 1000)))
            if let sp = screenshotPath {
                try? machine.Framebuffer?.SavePNG(to: fs.Path(sp))
            }
            machine.Terminate()
        }
    }

    if enableDisplay {
        let fbW = float32(cfg.Display.Width)
        let fbH = float32(cfg.Display.Height)
        var options = window.Options()
        options.Resizable = true
        options.MinSize = window.Size(640, 480)
        let initialW: float32 = max(fbW, 1024)
        let initialH: float32 = max(fbH, 768)
        let w = try window.Create(title: "Vertex VM — Ubuntu Desktop (ARM64)", size: window.Size(initialW, initialH), options: options)
        let surface = w.Surface()
        surface.SetScaling(.aspectFit)
        w.RequestFrame()

        var currentSize = window.Size(initialW, initialH)

        func mapPointerToTablet(_ pos: window.Point) -> (int32, int32)? {
            let scale = min(currentSize.Width / fbW, currentSize.Height / fbH)
            let dispW = fbW * scale
            let dispH = fbH * scale
            let originX = (currentSize.Width - dispW) * 0.5
            let originY = (currentSize.Height - dispH) * 0.5
            let relX = pos.X - originX
            let relY = pos.Y - originY
            if relX < 0 || relX >= dispW || relY < 0 || relY >= dispH {
                return nil
            }
            let normX = relX / dispW
            let normY = relY / dispH
            let absX = int32(normX * 32767.0)
            let absY = int32(normY * 32767.0)
            return (absX, absY)
        }

        print("[Host GUI] Window open. Controls: [Cmd+S] screenshot, [Cmd+Q/W] exit, mouse & keyboard active.")

        while let event = await w.WaitEvent() {
            switch event {
            case .closeRequested:
                w.Close()
                if let sp = screenshotPath {
                    try? machine.Framebuffer?.SavePNG(to: fs.Path(sp))
                }
                machine.Terminate()
                _ = try? await machine.Wait()
                print("\nVM closed from window.")
                return

            case .resized(let size):
                currentSize = size
                w.RequestFrame()

            case .pointerMoved(let ptr):
                if let (absX, absY) = mapPointerToTablet(ptr.Position) {
                    machine.TabletInput?.MoveAbsolute(x: absX, y: absY)
                }

            case .pointerDown(let ptr, let btn):
                if let (absX, absY) = mapPointerToTablet(ptr.Position) {
                    machine.TabletInput?.MoveAbsolute(x: absX, y: absY)
                }
                var buttonCode: int32 = 0
                switch btn {
                case .primary: buttonCode = 0
                case .secondary: buttonCode = 1
                case .middle: buttonCode = 2
                case .other: buttonCode = 0
                }
                machine.TabletInput?.Button(button: buttonCode, pressed: true)

            case .pointerUp(let ptr, let btn):
                if let (absX, absY) = mapPointerToTablet(ptr.Position) {
                    machine.TabletInput?.MoveAbsolute(x: absX, y: absY)
                }
                var buttonCode: int32 = 0
                switch btn {
                case .primary: buttonCode = 0
                case .secondary: buttonCode = 1
                case .middle: buttonCode = 2
                case .other: buttonCode = 0
                }
                machine.TabletInput?.Button(button: buttonCode, pressed: false)

            case .keyDown(let k):
                // Cmd shortcuts
                if k.Modifiers.Meta {
                    if k.Code == .q || k.Code == .w {
                        w.Close()
                        if let sp = screenshotPath {
                            try? machine.Framebuffer?.SavePNG(to: fs.Path(sp))
                        }
                        machine.Terminate()
                        _ = try? await machine.Wait()
                        print("\nVM closed from keyboard shortcut.")
                        return
                    } else if k.Code == .s {
                        if let fb = machine.Framebuffer {
                            let path = fs.Path(screenshotPath ?? "screenshot.png")
                            do {
                                try fb.SavePNG(to: path)
                                print("\n[Host] Saved screenshot to: \(path.Value)")
                            } catch {
                                print("\n[Host] Failed to save screenshot: \(error)")
                            }
                        }
                        continue
                    }
                }

                // 1. Forward evdev key to guest keyboard (for graphical / fbcon console)
                if let evdev = evdevCodeFor(k.Code) {
                    let val: uint32 = k.Repeat ? 2 : 1
                    machine.KeyboardInput?.Send(type: 1 /* EV_KEY */, code: evdev, value: val)
                    machine.KeyboardInput?.Send(type: 0 /* EV_SYN */, code: 0, value: 0)
                }

                // 2. Also forward to serial ConsoleUart (for serial console)
                if k.Modifiers.Control && k.Code.rawValue >= 1 && k.Code.rawValue <= 26 {
                    machine.ConsoleUart?.Feed([uint8(k.Code.rawValue)])
                    continue
                }

                switch k.Code {
                case .escape:
                    machine.ConsoleUart?.Feed([27])
                case .enter:
                    machine.ConsoleUart?.Feed([13])
                case .backspace:
                    machine.ConsoleUart?.Feed([127])
                case .tab:
                    machine.ConsoleUart?.Feed([9])
                case .delete:
                    machine.ConsoleUart?.Feed([27, 91, 51, 126]) // \x1b[3~
                case .arrowUp:
                    machine.ConsoleUart?.Feed([27, 91, 65]) // \x1b[A
                case .arrowDown:
                    machine.ConsoleUart?.Feed([27, 91, 66]) // \x1b[B
                case .arrowRight:
                    machine.ConsoleUart?.Feed([27, 91, 67]) // \x1b[C
                case .arrowLeft:
                    machine.ConsoleUart?.Feed([27, 91, 68]) // \x1b[D
                case .home:
                    machine.ConsoleUart?.Feed([27, 91, 72]) // \x1b[H
                case .end:
                    machine.ConsoleUart?.Feed([27, 91, 70]) // \x1b[F
                case .pageUp:
                    machine.ConsoleUart?.Feed([27, 91, 53, 126]) // \x1b[5~
                case .pageDown:
                    machine.ConsoleUart?.Feed([27, 91, 54, 126]) // \x1b[6~
                case .f1:
                    machine.ConsoleUart?.Feed([27, 79, 80])
                case .f2:
                    machine.ConsoleUart?.Feed([27, 79, 81])
                case .f3:
                    machine.ConsoleUart?.Feed([27, 79, 82])
                case .f4:
                    machine.ConsoleUart?.Feed([27, 79, 83])
                case .f5:
                    machine.ConsoleUart?.Feed([27, 91, 49, 53, 126])
                case .f6:
                    machine.ConsoleUart?.Feed([27, 91, 49, 55, 126])
                case .f7:
                    machine.ConsoleUart?.Feed([27, 91, 49, 56, 126])
                case .f8:
                    machine.ConsoleUart?.Feed([27, 91, 49, 57, 126])
                case .f9:
                    machine.ConsoleUart?.Feed([27, 91, 50, 48, 126])
                case .f10:
                    machine.ConsoleUart?.Feed([27, 91, 50, 49, 126])
                case .f11:
                    machine.ConsoleUart?.Feed([27, 91, 50, 51, 126])
                case .f12:
                    machine.ConsoleUart?.Feed([27, 91, 50, 52, 126])
                default:
                    break
                }

            case .keyUp(let k):
                if let evdev = evdevCodeFor(k.Code) {
                    machine.KeyboardInput?.Key(code: evdev, pressed: false)
                }

            case .text(let s):
                if s != "\r" && s != "\n" {
                    machine.ConsoleUart?.Feed([uint8](s.utf8))
                }

            case .frame(_):
                let snap = try? machine.Framebuffer?.Snapshot()
                if let s = snap, !s.isEmpty {
                    try? surface.Present(s, size: window.PixelSize(int32(fbW), int32(fbH)))
                }
                w.RequestFrame()

            default:
                break
            }
        }
    } else {
        let status = try await machine.Wait()
        if let sp = screenshotPath {
            try? machine.Framebuffer?.SavePNG(to: fs.Path(sp))
        }
        print("\nVM exited: \(status)")
    }
}

