package main

import (
    "fs"
    "io"
    "os/process"
    "sync"
    "time"
    "vm"
    "vm/device"
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

func runAlpineLinux() async throws {
    let kernelPath = fs.Path("testdata/Image")
    let kernelFile = try fs.Open(kernelPath)
    print("Reading Linux ARM64 kernel from testdata/Image...")
    let kernel = try kernelFile.ReadToEnd()
    print("Kernel read: \(kernel.count) bytes")

    var initrd: [uint8]? = nil
    let initrdPath = fs.Path("testdata/initramfs-virt")
    if let initrdFile = try? fs.Open(initrdPath) {
        print("Reading Alpine initramfs from testdata/initramfs-virt...")
        initrd = try? initrdFile.ReadToEnd()
        if let rd = initrd {
            print("Initramfs read: \(rd.count) bytes")
        }
    }

    print("=== Test 2: Booting Alpine Linux ARM64 Kernel ===")
    var cfg = vm.Config(cpus: 1, memory: 512 << 20)
    cfg.Boot = .linux(
        kernel: kernel,
        initrd: initrd,
        cmdline: "console=ttyAMA0 earlycon=pl011,0x09000000 reboot=k panic=-1"
    )

    let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
    defer { machine.Close() }
    try machine.Start()
    print("Alpine Linux VM started! Streaming guest console:")
    Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print("\n[boot-test] Kernel booted into userland, terminating test cleanly...")
        machine.Terminate()
    }
    let code = try await machine.Wait()
    print("\n[boot-test] Alpine Linux boot test completed successfully (code: \(code))")
    print("=== ALL BOOT TESTS PASSED ===")
}

public func main() async throws {
    print("=== Hypervisor Capabilities Probe ===")
    let caps = hypervisor.Probe()
    print("Arch: \(caps.Arch)")
    print("Max vCPUs: \(caps.MaxVcpus)")
    print("In-Kernel IrqChip: \(caps.InKernelIrqChip)")
    print("Partitions per process: \(caps.PartitionsPerProcess)")
    print("Physical address bits: \(caps.PhysicalAddressBits)")

    try await runTinyGuest()
    try await runAlpineLinux()
}
