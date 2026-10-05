import (
    "fs"
    "io"
    "net/nat"
    "os/env"
    "os/process"
    "sync"
    "time"
    "ui/window"
    "vm"
    "vm/android"
    "vm/boot"
    "vm/chipset"
    "vm/device"
    "vm/disk"
    "vm/gfxstream"
    "vm/goldfish"
    "vm/hypervisor"
    "vm/windows"
)

func printUsage() {
    print("""
Usage: vm-run [options]

Options:
  --kernel <path>    Path to Linux ARM64 kernel Image or vmlinuz (supports raw, gzip, EFI zboot)
  --initrd <path>    Path to initramfs image
  --cmdline <str>    Kernel command line arguments
  --memory <MB>      Guest physical memory in MB (default: 512)
  --cpus <N>         Number of virtual CPUs (default: 1)
  --disk <path>      Path to disk image (raw/qcow2) to attach as VirtIO block device (repeatable: vda, vdb, …)
  --android <dir>    Boot an Android emulator image (vmimage --clone android:5 <dir>): its kernel, ramdisk and disks
  --gles             Android 8+: draw through vm's host renderer (the emulator's GPU pipe) instead of hiding it
  --gles-record <dir>  With --gles: keep each GL stream the guest sends, for replaying in checks
  --gles-cpu         With --gles: draw on the CPU, not the Mac's GPU
  --cdrom, --iso <p> Path to ISO optical disc image to attach as read-only installer media
  --display, --gui   Open graphical window for guest framebuffer
  --width <px>       Guest framebuffer width (default: 1024)
  --height <px>      Guest framebuffer height (default: 768)
  --screenshot <path> Save guest framebuffer snapshot to PNG file
  --timeout <sec>    Automatically terminate VM after N seconds
  --firmware <path>  UEFI firmware code (default: firmware/AAVMF_CODE.secboot.fd.gz, Secure Boot)
  --vars <path>      UEFI variable store template (default: saved beside the disk)
  --disk-size <GB>   Size of a disk --disk creates for Windows (default: 64)
  --no-tpm           Give a Windows guest no TPM 2.0 (default: swtpm, state beside the disk)
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

    var kernelPath = ""
    var initrdPath: string? = nil
    var cmdline = "console=ttyAMA0 earlycon=pl011,0x09000000 reboot=k panic=-1"
    var memoryMb: uint64 = 512
    var cpus: int = 1
    var diskPath: string? = nil
    var extraDisks: [string] = []
    var cdromPath: string? = nil
    var enableDisplay = false
    var displayWidth: int = 1024
    var displayHeight: int = 768
    var screenshotPath: string? = nil
    var screenshotDelaySec: int = 5
    var timeoutSec: int? = nil
    var enableNet = true
    var guestCommand: string? = nil
    var hostGles = false
    var glesRecordDir: string? = nil
    var glesCPU = false
    var commandDelayMs: int = 5600
    var explicitKernel = false
    var explicitInitrd = false
    var explicitCmdline = false
    var firmwarePath: string? = nil
    var varsPath: string? = nil
    var diskSizeGiB: uint64 = 64
    var explicitMemory = false
    var explicitCpus = false
    var enableTpm = true
    var androidDir: string? = nil
    var explicitSize = false

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
                    explicitSize = true
                }
                i += 1
            }
        case "--height":
            if i + 1 < args.count {
                if let h = int(args[i + 1]), h > 0 {
                    displayHeight = h
                    explicitSize = true
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
                    explicitMemory = true
                }
                i += 1
            }
        case "--cpus":
            if i + 1 < args.count {
                if let c = int(args[i + 1]), c > 0 {
                    cpus = c
                    explicitCpus = true
                }
                i += 1
            }
        case "--disk":
            if i + 1 < args.count {
                // Repeatable: the first is vda (and Windows' disk), the rest follow.
                if diskPath == nil { diskPath = args[i + 1] } else { extraDisks.append(args[i + 1]) }
                i += 1
            }
        case "--no-tpm":
            enableTpm = false
        case "--firmware":
            if i + 1 < args.count {
                firmwarePath = args[i + 1]
                i += 1
            }
        case "--vars":
            if i + 1 < args.count {
                varsPath = args[i + 1]
                i += 1
            }
        case "--disk-size":
            if i + 1 < args.count {
                if let g = int(args[i + 1]), g > 0 {
                    diskSizeGiB = uint64(g)
                }
                i += 1
            }
        case "--gles":
            hostGles = true
        case "--gles-cpu":
            hostGles = true
            glesCPU = true
        case "--gles-record":
            hostGles = true
            if i + 1 < args.count {
                glesRecordDir = args[i + 1]
                i += 1
            }
        case "--android":
            if i + 1 < args.count {
                androidDir = args[i + 1]
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

    // A Windows ARM64 ISO boots under UEFI with devices Windows has
    // drivers for; see windows.vs.
    if let cp = cdromPath, !explicitKernel, let info = (try? windows.DetectIso(cp)) ?? nil, info.IsArm64 {
        print("[ISO] \(info.Edition) (\(info.VolumeId))")
        var o = WindowsOptions(Iso: cp)
        o.Disk = diskPath
        o.DiskSize = diskSizeGiB << 30
        o.Firmware = firmwarePath
        o.Vars = varsPath
        o.MemoryMiB = explicitMemory ? int(memoryMb) : 4096
        o.Cpus = explicitCpus ? cpus : 4
        o.Screenshot = screenshotPath
        o.TimeoutSec = timeoutSec
        o.Display = enableDisplay || screenshotPath == nil
        o.Tpm = enableTpm
        try await runWindows(o)
        return
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
    var kernelDisplayName = kernelPath.isEmpty ? (androidDir.map { $0 + "/kernel-ranchu" } ?? "") : kernelPath
    var initrdDisplayName = initrdPath ?? androidDir.map { $0 + "/ramdisk.img" }

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

    // An Android emulator image (a `vmimage --clone android:<release>`
    // directory): its kernel, ramdisk and disks, a phone-shaped screen.
    var androidBundle: android.Bundle? = nil
    var bootProps = android.BootProperties()
    if let ad = androidDir {
        do {
            let b = try android.Bundle.Open(ad)
            androidBundle = b
            kernelPath = b.Kernel
            if !explicitMemory { memoryMb = 2048 }
            if !explicitCpus { cpus = 2 }
            if !explicitSize {
                displayWidth = 720
                displayHeight = 1280
            }
            // The emulator's boot properties (heap, density, navigation
            // bar), added to the ramdisk's default.prop.
            bootProps = android.BootProperties.ForScreen(width: displayWidth)
            bootProps.HostGpu = hostGles
            bootProps.SystemAsRoot = b.SystemAsRoot
            if !explicitCmdline { cmdline = b.Cmdline(hostGpu: hostGles, props: bootProps) }
            if !b.SystemAsRoot {
                initrdPath = b.Ramdisk
                initrdBytes = try b.BootRamdisk(bootProps)
            }
            print("[Android] \(b.Release.isEmpty ? "API \(b.ApiLevel)" : "Android \(b.Release) (API \(b.ApiLevel))") from \(b.Dir)")
        } catch {
            print("Error: \(error)")
            return
        }
    }

    if kernelBytes == nil && kernelPath.isEmpty {
        print("Error: no kernel: give --kernel (and --initrd), --iso, or run a container image with `container run`")
        printUsage()
        return
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
    if let (major, minor) = boot.LinuxVersion(kernel), major < 4 {
        print("[Kernel] Linux \(major).\(minor): VirtIO MMIO devices speak version 1 (legacy)")
        cfg.LegacyVirtio = true
    }
    if enableDisplay || screenshotPath != nil {
        cfg.Display = .custom(width: displayWidth, height: displayHeight)
    }
    if let b = androidBundle {
        // The image's disks in its fstabs' order (GPT partitions opened
        // as disks), then any --disk given; and its first-stage mounts.
        do {
            for img in try await b.OpenDisks() { cfg.Storage.append(.disk(img)) }
        } catch {
            print("Error: opening the image's disks: \(error)")
            return
        }
        cfg.AndroidMounts = b.EarlyMounts
        cfg.Guest = .android
        // Android can't run without a screen (SurfaceFlinger aborts), so
        // it always has one; --display only decides whether a window shows it.
        cfg.Display = .custom(width: displayWidth, height: displayHeight)
    }
    if enableNet {
        if androidBundle != nil {
            // The emulator's network, which Android's init.goldfish.sh
            // configures statically: 10.0.2.15, gateway .2, DNS .3.
            cfg.Network.append(.nat(nat.Config.slirp))
        } else {
            cfg.Network.append(.nat())
        }
    }

    // Optional disks, in order: vda, vdb, …
    for dp in (diskPath.map { [$0] } ?? []) + extraDisks {
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
    print("Network:    \(enableNet ? (androidBundle != nil ? "User-space NAT (guest 10.0.2.15, gateway 10.0.2.2, DNS 10.0.2.3)" : "User-space NAT (192.168.127.1, DHCP, DNS)") : "disabled")")
    print("Display:    \(cfg.Display.Enabled ? "\(cfg.Display.Width)x\(cfg.Display.Height) graphical framebuffer" : "none (headless)")")
    if let sp = screenshotPath {
        print("Screenshot: \(sp)")
    }
    print("Cmdline:    \(cmdline)")
    print("---------------------------------")

    let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
    defer { machine.Close() }

    // The host services Android reaches through its pipe.
    var renderer: gfxstream.Renderer? = nil
    if let pipe = machine.GoldfishPipe {
        pipe.Register("qemud:boot-properties", goldfish.QemudPipe(android.BootPropertiesService(bootProps)))
        let logcatPipe = android.LogcatService()
        logcatPipe.OnLine = { line in print("[logcat] \(line)") }
        pipe.Register("logcat", logcatPipe)
        if hostGles {
            let r = gfxstream.Renderer(width: displayWidth, height: displayHeight, dpi: bootProps.Density)
            r.RecordDir = glesRecordDir
            if !glesCPU {
                print(r.UseGPU() ? "[gles] drawing on the GPU (Metal)" : "[gles] no Metal device: drawing on the CPU")
            }
            if let fb = machine.Framebuffer {
                r.OnPost = { pixels, w, h in fb.PresentHost(pixels, width: w, height: h) }
            }
            pipe.Register("opengles", r)
            renderer = r
        }
    }
    defer {
        if let r = renderer {
            let top = r.Unimplemented.prefix(40).map { "\($0.0)×\($0.1)" }
            if !top.isEmpty { print("[gles] not carried out yet: \(top.joined(separator: ", "))") }
            if !r.Errors.isEmpty { print("[gles] stream errors: \(r.Errors.prefix(5))") }
            let g = r.GPUStats
            if g.Draws > 0 || g.Fallbacks > 0 {
                print("[gles] GPU: \(g.Draws) draws, \(g.Clears) clears, \(g.Uploads) uploads, \(g.Readbacks) readbacks, \(g.Fallbacks) on the CPU")
                if !g.LastFailure.isEmpty { print("[gles] last program the GPU couldn't take: \(g.LastFailure)") }
            }
        }
    }
    defer {
        if let pipe = machine.GoldfishPipe, !pipe.Refused.isEmpty {
            var names: [string] = []
            for n in pipe.Refused where !names.contains(n) { names.append(n) }   // vsc_TODO #43
            print("[Android] pipe services asked for that vm doesn't have: \(names.sorted().joined(separator: ", "))")
        }
    }

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

    // A debugging aid for Android's touchscreen without a window:
    // VERTEX_VM_TAP="x,y@seconds;…" taps those screen pixels then.
    if let taps = env.Get("VERTEX_VM_TAP"), let ev = machine.GoldfishEvents {
        for t in taps.split(separator: ";") {
            let parts = t.split(separator: "@")
            let xy = parts.first.map { $0.split(separator: ",") } ?? []
            guard parts.count == 2, xy.count == 2, let x = int(string(xy[0])), let y = int(string(xy[1])),
                  let sec = int(string(parts[1])) else { continue }
            Task {
                try? await time.Sleep(.Milliseconds(int64(sec * 1000)))
                print("\n[Host] tap \(x),\(y)")
                ev.Touch(x: x, y: y, down: true)
                try? await time.Sleep(.Milliseconds(80))
                ev.Touch(x: x, y: y, down: false)
            }
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
            if env.Get("VERTEX_VM_DUMP") != nil {
                for v in machine.Vcpus {
                    let (_, _, st) = v.CurrentState()
                    print("\n[vCPU \(v.Id) at timeout] \(st)")
                }
            }
            if let sp = screenshotPath {
                try? machine.Framebuffer?.SavePNG(to: fs.Path(sp))
            }
            machine.Terminate()
            if enableDisplay {
                // The window's event loop would keep the process alive.
                _ = try? await machine.Wait()
                print("\nVM exited: timeout")
                process.Exit(0)
            }
        }
    }

    if enableDisplay {
        let fbW = float32(cfg.Display.Width)
        let fbH = float32(cfg.Display.Height)
        var options = window.Options()
        options.Resizable = true
        options.MinSize = fbH > fbW ? window.Size(240, 400) : window.Size(640, 480)
        var initialW: float32 = max(fbW, 1024)
        var initialH: float32 = max(fbH, 768)
        if fbH > fbW {
            // A phone: its own shape, no taller than a laptop screen holds.
            initialH = min(fbH, 900)
            initialW = fbW * initialH / fbH
        }
        let title = androidBundle.map { "Vertex VM — Android " + ($0.Release.isEmpty ? "API \($0.ApiLevel)" : $0.Release) } ?? "Vertex VM — Ubuntu Desktop (ARM64)"
        let w = try window.Create(title: title, size: window.Size(initialW, initialH), options: options)
        let surface = w.Surface()
        surface.SetScaling(.aspectFit)
        w.RequestFrame()

        var currentSize = window.Size(initialW, initialH)
        var lastFrames: uint64 = ~0
        var lastPresent = time.Instant.Now()

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

        /// The screen pixel under the pointer, for Android's touchscreen.
        func mapPointerToScreen(_ pos: window.Point) -> (int, int)? {
            guard let (ax, ay) = mapPointerToTablet(pos) else { return nil }
            return (int(float32(ax) / 32767.0 * fbW), int(float32(ay) / 32767.0 * fbH))
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
                if let ev = machine.GoldfishEvents {
                    if ev.Touching, let (x, y) = mapPointerToScreen(ptr.Position) { ev.Touch(x: x, y: y, down: true) }
                    continue
                }
                if let (absX, absY) = mapPointerToTablet(ptr.Position) {
                    machine.TabletInput?.MoveAbsolute(x: absX, y: absY)
                }

            case .pointerDown(let ptr, let btn):
                if let ev = machine.GoldfishEvents {
                    if btn == .secondary {
                        ev.Key(158, pressed: true)   // KEY_BACK
                        ev.Key(158, pressed: false)
                    } else if let (x, y) = mapPointerToScreen(ptr.Position) {
                        ev.Touch(x: x, y: y, down: true)
                    }
                    continue
                }
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
                if let ev = machine.GoldfishEvents {
                    if ev.Touching {
                        let (x, y) = mapPointerToScreen(ptr.Position) ?? (0, 0)
                        ev.Touch(x: x, y: y, down: false)
                    }
                    continue
                }
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

                // Android: its keyboard; Home and Escape are its Home and Back keys.
                if let ev = machine.GoldfishEvents {
                    if k.Code == .home { ev.Key(102, pressed: true) }          // KEY_HOME
                    else if k.Code == .escape { ev.Key(158, pressed: true) }   // KEY_BACK
                    else if let evdev = evdevCodeFor(k.Code), !k.Repeat { ev.Key(evdev, pressed: true) }
                    continue
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
                if let ev = machine.GoldfishEvents {
                    if k.Code == .home { ev.Key(102, pressed: false) }
                    else if k.Code == .escape { ev.Key(158, pressed: false) }
                    else if let evdev = evdevCodeFor(k.Code) { ev.Key(evdev, pressed: false) }
                    continue
                }
                if let evdev = evdevCodeFor(k.Code) {
                    machine.KeyboardInput?.Key(code: evdev, pressed: false)
                }

            case .text(let s):
                if machine.GoldfishEvents != nil { continue }
                if s != "\r" && s != "\n" {
                    machine.ConsoleUart?.Feed([uint8](s.utf8))
                }

            case .frame(_):
                // Redraw when the guest posted a frame, or now and then
                // for screens drawn in place; converting the screen on
                // every host frame starves the device tasks this thread
                // also runs (a guest's disk I/O among them).
                if let fb = machine.Framebuffer {
                    let frames = fb.Frames
                    let since = lastPresent.Elapsed().AsMilliseconds()
                    if frames != lastFrames || since >= (frames == 0 ? 33 : 500) {
                        lastFrames = frames
                        lastPresent = time.Instant.Now()
                        if let s = try? fb.Snapshot(), !s.isEmpty {
                            try? surface.Present(s, size: window.PixelSize(int32(fbW), int32(fbH)))
                        }
                    }
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

