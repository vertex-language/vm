package main

import (
    "fs"
    "io"
    "os/process"
    "sync"
    "time"
    "vm"
    "vm/device"
    "vm/disk"
    "vm/usb"
    "vm/windows"
    "vm/hypervisor"
)

/// Embedded 132-byte ARM64 test kernel:
/// 1. 64-byte Linux arm64 Image header
/// 2. Code writes "HELLO\n" to PL011 UART at 0x09000000
/// 3. PSCI 0x84000008 (SYSTEM_OFF) via HVC #0
let tinyKernel: [uint8] = [
    16, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 65, 82, 77, 100, 0, 0, 0, 0,
    1, 32, 161, 210, 0, 9, 128, 82, 32, 0, 0, 57, 160, 8, 128, 82,
    32, 0, 0, 57, 128, 9, 128, 82, 32, 0, 0, 57, 128, 9, 128, 82,
    32, 0, 0, 57, 224, 9, 128, 82, 32, 0, 0, 57, 64, 1, 128, 82,
    32, 0, 0, 57, 0, 1, 128, 210, 0, 128, 176, 242, 2, 0, 0, 212,
    0, 0, 0, 20
]

func runTinyGuest() async throws {
    print("=== Test 1: Tiny ARM64 Bare-Metal Guest ===")
    let memConsole = vm.MemoryConsole()
    var cfg = vm.Config(cpus: 1, memory: 128 << 20)
    cfg.Boot = .linux(kernel: tinyKernel, initrd: nil, cmdline: "console=ttyAMA0")

    let machine = try vm.Create(cfg, consoleWriter: memConsole)
    defer { machine.Close() }
    try machine.Start()
    print("Machine started, awaiting vCPU exit...")
    let code = try await machine.Wait()
    print("Machine exited with code: \(code)")
    let output = memConsole.Text
    print("Console captured output: \(output)")
    if output.contains("HELLO") {
        print("PASS: Tiny guest successfully executed on hypervisor and printed HELLO!")
    } else {
        print("FAIL: Expected output to contain 'HELLO', got: '\(output)'")
    }
}

/// Executes `mrs x8, pmcr_el0`, then PSCI SYSTEM_OFF: shows whether the
/// hypervisor traps PMU registers to us or injects UNDEF itself.
func runPmuProbe() async throws {
    print("=== Test: PMU sysreg probe ===")
    var k = [uint8](tinyKernel[0..<64])
    let words: [uint32] = [
        0xd2800008, // mov x8, #0
        0xd53b9c08, // mrs x8, pmcr_el0
        0xaa0803e1, // mov x1, x8
        0xd2800100, // mov x0, #8
        0xf2b08000, // movk x0, #0x8400, lsl #16
        0xd4000002, // hvc #0
        0x14000000  // b .
    ]
    for w in words {
        k.append(contentsOf: [uint8(w & 0xff), uint8((w >> 8) & 0xff), uint8((w >> 16) & 0xff), uint8(w >> 24)])
    }
    var cfg = vm.Config(cpus: 1, memory: 128 << 20)
    cfg.Boot = .linux(kernel: k, initrd: nil, cmdline: "")
    let machine = try vm.Create(cfg, consoleWriter: vm.MemoryConsole())
    defer { machine.Close() }
    try machine.Start()
    Task {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let (_, _, st) = machine.Vcpus[0].CurrentState()
        print("PMU probe timed out: \(st)")
        machine.Terminate()
    }
    let code = try await machine.Wait()
    print("PMU probe exited: \(code) counts=\(machine.Vcpus[0].ExitCounts)")
}

public func main() async throws {
    if process.Args.count > 1 && process.Args[1] == "pmu" {
        try await runPmuProbe()
        return
    }
    try await runEfiFirmware()
}

/// Finds the XSDT the firmware installed and prints what it points at.
func dumpAcpi(_ machine: vm.Machine) {
    let base = machine.Ram.Range.Base
    let size = machine.Ram.Range.Count
    let chunk: uint64 = 1 << 20
    var off: uint64 = 0
    while off < size {
        guard let b = try? machine.Ram.Memory.Read(device.GuestAddress(base + off), count: int(chunk)) else { off += chunk; continue }
        var i = 0
        while i + 36 <= b.count {
            if b[i] == 0x52 && b[i+1] == 0x53 && b[i+2] == 0x44 && b[i+3] == 0x20 && b[i+4] == 0x50 && b[i+5] == 0x54 && b[i+6] == 0x52 {
                var x: uint64 = 0
                for k in 0..<8 { x |= uint64(b[i + 24 + k]) << (8 * uint64(k)) }
                print("[acpi] RSDP at 0x\(string(base + off + uint64(i), radix: 16)) rev=\(b[i+15]) xsdt=0x\(string(x, radix: 16))")
            }
            if b[i] == 0x58 && b[i+1] == 0x53 && b[i+2] == 0x44 && b[i+3] == 0x54 {
                let len = int(b[i+4]) | (int(b[i+5]) << 8) | (int(b[i+6]) << 16) | (int(b[i+7]) << 24)
                if len >= 36 && len < 4096 && i + len <= b.count {
                    var s = "[acpi] XSDT at 0x\(string(base + off + uint64(i), radix: 16)) len=\(len):"
                    var e = i + 36
                    while e + 8 <= i + len {
                        var a: uint64 = 0
                        for k in 0..<8 { a |= uint64(b[e + k]) << (8 * uint64(k)) }
                        var sig = "????"
                        if let t = try? machine.Ram.Memory.Read(device.GuestAddress(a), count: 8) {
                            sig = string(decoding: t[0..<4], as: UTF8.self)
                            let tl = int(t[4]) | (int(t[5]) << 8) | (int(t[6]) << 16) | (int(t[7]) << 24)
                            sig += "(\(tl))"
                        }
                        s += " 0x\(string(a, radix: 16))=\(sig)"
                        e += 8
                    }
                    print(s)
                }
            }
            i += 4
        }
        off += chunk
    }
}

func runEfiFirmware() async throws {
    // The bundled Secure Boot firmware, unless `fw=<code.fd>` and
    // `vars=<vars.fd>` pick other firmware.
    var codeArg: string? = nil
    var varsArg: string? = nil
    for a in process.Args {
        if a.hasPrefix("fw=") { codeArg = string(a.dropFirst(3)) }
        if a.hasPrefix("vars=") { varsArg = string(a.dropFirst(5)) }
    }
    let fw = try windows.FindFirmware(customCodePath: codeArg, customVarsPath: varsArg)
    print("=== Test 3: Booting UEFI firmware \(fw.Name) (Secure Boot \(fw.SecureBoot ? "on" : "off")) ===")
    let firmware = fw.Code
    let vars: [uint8]? = fw.VarsTemplate

    var cfg = vm.Config(cpus: 2, memory: 4096 << 20)
    cfg.Boot = .efi(firmware: firmware, vars: vars)
    cfg.Profile = .standard
    cfg.Guest = .windows
    cfg.Display = .custom(width: 1024, height: 768)

    let isoPath = fs.Path("/Users/galaxy/Desktop/Windows11_Client_arm64_en-us_26300_9457.iso")
    if let isoDisk = try? await vm.OpenDisk(isoPath, readOnly: true) {
        print("Attached Windows ARM64 ISO: \(isoPath.Value)")
        cfg.Storage.append(.installer(isoDisk))
    }
    // The disk Windows installs to, sparse.
    let targetPath = fs.Path("testdata/windows-target.raw")
    let target = (try? disk.OpenRaw(targetPath)) ?? (try disk.CreateRaw(targetPath, size: 64 << 30))
    cfg.Storage.append(.disk(target))
    if !process.Args.contains("no-tpm") {
        cfg.Tpm = .swtpm(stateDir: "testdata/windows-target.tpm")
    }

    let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
    defer { machine.Close() }
    if process.Args.contains("trace") {
        machine.Wired.Xhci?.Trace = true
    }
    if process.Args.contains("trace-nvme") {
        machine.Wired.Nvme?.Trace = true
    }
    if process.Args.contains("trace-late") {
        // Only what Windows does: firmware is done after ~25 s.
        Task {
            try? await Task.sleep(nanoseconds: 22_000_000_000)
            machine.Wired.Xhci?.Trace = true
        }
    }
    try machine.Start()
    print("UEFI VM started! Streaming guest console:")
    Task {
        for sec in 1...(process.Args.contains("trace") ? 60 : (process.Args.contains("trace-late") ? 70 : (process.Args.contains("trace-nvme") ? 75 : 90))) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if sec >= 6 && sec <= 14 {
                // Feed Enter and Space to both UART and virtio-keyboard
                machine.ConsoleUart?.Feed([13, 10, 32])
                machine.UsbKeyboard?.Key(0x2c /* space */, pressed: true)
                machine.UsbKeyboard?.Key(0x2c, pressed: false)
            }
            if sec == 9 && process.Args.count > 1 && process.Args[1] == "acpi" {
                dumpAcpi(machine)
                // The top 64 MiB of RAM, where the firmware puts its tables.
                let top = machine.Ram.Range.End - (64 << 20)
                if let b = try? machine.Ram.Memory.Read(device.GuestAddress(top), count: 64 << 20),
                   let f = try? fs.Create(fs.Path("ram_hi.bin")) {
                    try? f.Write(b)
                    try? f.Close()
                    print("[acpi] wrote ram_hi.bin from 0x\(string(top, radix: 16))")
                }
                machine.Terminate()
                break
            }
            if sec % 30 == 0, let x = machine.Wired.Xhci {
                let cmd = x.Config.Read(offset: 0x04, size: 2)
                let cap = int(x.Config.Read(offset: 0x34, size: 1))
                var ctl = ""
                var at = cap
                while at != 0 {
                    let id = x.Config.Read(offset: at, size: 1)
                    if id == 0x11 { ctl = "0x" + string(x.Config.Read(offset: at + 2, size: 2), radix: 16) }
                    at = int(x.Config.Read(offset: at + 1, size: 1))
                }
                print("[boot-test] xhci command=0x\(string(cmd, radix: 16)) msix control=\(ctl)")
            }
            if sec % 30 == 0 {
                for (i, v) in machine.Vcpus.enumerated() {
                    let (_, _, state) = v.CurrentState()
                    print("[boot-test] [\(sec)s] vCPU \(i): \(state)")
                    if let regs = v.LastRegisters, let mmu = v.LastMmu {
                        for (label, va) in [("PC", regs.Pc), ("ELR", regs.ElrEl1), ("LR", regs.X[30])] {
                            if let code = mmu.Read(va - 32, count: 64, memory: machine.Ram.Memory) {
                                var hex = ""
                                for b in code { hex += "0x\(string(b, radix: 16)) " }
                                print("[code] \(label) 0x\(string(va - 32, radix: 16)): \(hex)")
                            }
                        }
                    }
                }
            }
            if sec % 10 == 0, let t = machine.Wired.Tpm {
                print("[boot-test] [\(sec)s] TPM commands: \(t.CommandCount)")
            }
            if sec % 10 == 0 {
                if let fb = machine.Framebuffer, fb.Configured {
                    let outPath = fs.Path("uefi_sec_\(sec).png")
                    try? fb.SavePNG(to: outPath)
                    print("[boot-test] [\(sec)s] Saved \(outPath.Value) (\(fb.Width)x\(fb.Height))")
                } else {
                    print("[boot-test] [\(sec)s] Framebuffer not configured yet")
                }
            }
        }
        print("\n[boot-test] Terminating UEFI test after timeout...")
        machine.Terminate()
    }
    let code = try await machine.Wait()
    print("\n[boot-test] UEFI test completed (code: \(code))")
}
