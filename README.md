# `vm`: Native Virtual Machines in Vertex

`vm` provides native hardware virtualization for Vertex running directly on the host operating system's hypervisor:
- **macOS (Apple Silicon)**: `Hypervisor.framework` (ARM64 with in-kernel GICv3 via `hv_gic` on macOS 15+)
- **Windows**: Windows Hypervisor Platform (`WinHvPlatform`)
- **Linux**: Kernel-based Virtual Machine (`/dev/kvm`)

Zero instruction emulation. Zero QEMU or libvirt dependencies. 100% native CPU and hardware-accelerated guest execution where the guest architecture matches the host.

---

## 1. Implemented Architecture

```
 User Program / CLI      │ import "vm"  (or ./vm-run, ./disk-tool)
                         │ let machine = try vm.Create(cfg); try machine.Start(); await machine.Wait()
═════════════════════════╪═════════════════════════════════════════════════════════════════════════════════════
 vm                      │ Machine lifecycle · Config by role · GuestRam mapping
                         │ Dedicated vCPU OS threads (sync.Thread) · PSCI 1.0 handler
                         │ Flattened Device Tree generator (encoding/fdt) with KASLR & RNG seeds
─────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────
 Devices (Active Micro)  │ • VirtIO MMIO (v2): Block, Net, Input (Tablet & Keyboard), Entropy (RNG)
                         │ • Chipset: ARM PrimeCell PL011 UART (ttyAMA0), ARM PrimeCell PL031 RTC
                         │ • Graphics: 32bpp linear software framebuffer (simple-framebuffer)
─────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────
 Boot Protocols          │ • Universal Linux ARM64 boot loader (vm/boot)
                         │ • Automated kernel unpacking: Raw ARM64, EFI zboot (Zstandard & Gzip), RFC 1952 Gzip
─────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────
 Storage & Media         │ • Raw sparse disk images (.raw, .img)
                         │ • Pure-Vertex ISO 9660 filesystem parser with El Torito boot discovery & file extraction
                         │ • QCOW2 v2/v3 cluster reader (vm/disk/qcow2) · VHDX reader (vm/disk/vhdx)
─────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────
 User-Space Networking   │ • Pure user-space NAT (net/nat): DHCP lease daemon, ARP, ICMP echo
                         │ • DNS proxy to upstream resolvers · Outbound TCP connection proxying (net/tcp)
═════════════════════════╪═════════════════════════════════════════════════════════════════════════════════════
 vm/device Contract      │ GuestMemory (pointer-backed RAM) · MmioBus · PioBus · Irq lines · Msi
═════════════════════════╪═════════════════════════════════════════════════════════════════════════════════════
 vm/hypervisor (Native)  │ Partition · Vcpu · Memory mapping (hv_vm_map) · Exits (MMIO, hypercall, sysreg)
                         │ C++ bridge: hv_darwin.cpp (HVF) · hv_windows.cpp (WHP) · hv_linux.cpp (KVM)
```

---

## 2. Package Summary

| Package | Status | What It Does |
| :--- | :--- | :--- |
| **`vm`** | **Production** | Machine lifecycle (`Create`, `Start`, `Wait`, `Terminate`, `Close`), memory layout, vCPU thread coordination, platform wiring, and Device Tree generation. |
| **`vm/hypervisor`** | **Production** | Thin, high-performance C++ hypervisor bridge (`hv_darwin.cpp`, `hv_windows.cpp`, `hv_linux.cpp`). Manages partitions, vCPU registers (`regs_arm64.vs`), dirty logging, and exit dispatch. |
| **`vm/device`** | **Production** | Abstraction contracts used by all virtual devices: `GuestMemory`, `Mmio`, `Pio`, `MmioBus`, `PioBus`, `Irq`, `Msi`, and memory `Range`. |
| **`vm/boot`** | **Production** | Kernel loaders and decompressors: `LinuxArm64` direct image boot, universal kernel sniffer & decompressor (`DetectKernelFormat`, `UnpackKernel`), PVH ELF (`boot/pvh.vs`), and bzImage (`boot/bzimage.vs`). |
| **`vm/virtio`** | **Production** | VirtIO 1.2 specification implementation: modern MMIO transport (`virtio/mmio.vs`), split virtqueue ring engine (`virtio/queue.vs`), block device (`virtio.Block`), network device (`virtio.Net`), tablet & keyboard input (`virtio.Input`), and hardware entropy device (`virtio.Rng`). |
| **`vm/chipset`** | **Production** | Platform peripherals: ARM PrimeCell PL011 UART (`ttyAMA0` with FIFO and interrupt signaling) and ARM PrimeCell PL031 Real-Time Clock. |
| **`vm/display`** | **Production** | Double-buffered 32bpp XRGB8888 software framebuffer mapped at GPA `0x3000_0000`, simple-framebuffer Device Tree node, and snapshot RGBA exporter. |
| **`vm/pci`** | **Production** | PCIe root complex: ECAM configuration space with writable masks, BARs decoded where the guest programs them (`Root.MmioWindow`), MSI-X (delivered through the GIC's MSI frame), level-triggered INTx swizzled onto SPIs 3–6, and a PCIe capability. |
| **`vm/nvme`** | **Production** | NVMe 1.4 controller on MSI-X or INTx: admin and I/O queue pairs, Identify, features, log pages, read/write/flush/write zeroes/deallocate, chained PRP lists. Windows' `stornvme` drives it inbox. |
| **`vm/usb`** | **Production** | xHCI controller with a USB 2.0 root hub: command and event rings, slots and endpoint contexts, control/bulk/interrupt transfers. Devices: HID keyboard and tablet, and bulk-only mass storage as a CD-ROM (SCSI/MMC) or disk. |
| **`vm/windows`** | **Production** | Windows ARM64 ISO detection, EDK2 firmware lookup, and the machine configuration Windows installs on. |
| **`vm/disk`** | **Production** | Disk backend protocol (`Image`), raw disk driver, pure-Vertex ISO 9660 filesystem parser (`disk/iso.vs` with PVD, El Torito, directory reader, boot file discovery, and chunked extraction), QCOW2 reader (`disk/qcow2`), and VHDX reader (`disk/vhdx`). |

---

## 3. Included CLI Programs

The repository includes four executable tools in `cmd/`:

### 1. `vm-run` (`cmd/vm-run`)
Interactive virtual machine runner supporting headless microVMs, graphical desktop live ISOs, and automated distribution installers.
- **One-Click ISO Boot**: Automatically detects optical discs (`--iso <path>`), inspects ISO 9660 directory structures, locates the kernel and initramfs, extracts them in memory, adjusts memory and CPU sizing, and configures distribution-specific command lines.
- **Kernel Auto-Decompression**: Transparently detects and unpacks raw ARM64 Images, Gzip streams, and EFI zboot PE executables (Zstandard / Gzip) on the fly.
- **Interactive Graphical Window**: Powered by `ui/window` with dynamic aspect-fit scaling (`ScalingMode.aspectFit`), letterboxing, resizable window support, VirtIO absolute tablet pointer tracking, and full keyboard event forwarding.
- **User-Space NAT Networking**: Out-of-the-box guest internet connectivity without root/sudo, host bridges, or TUN/TAP devices (DHCP server, ARP, ICMP echo, DNS proxy, TCP socket translation).
- **Screenshot Capture**: Snapshot the guest framebuffer directly to a PNG file (`--screenshot <path>`).

### 2. `disk-tool` (`cmd/disk`)
Comprehensive disk and ISO management utility:
- `info <path>`: Inspects partition and format metadata (QCOW2, VHDX, Raw, ISO 9660).
- `list-iso <iso> [dir]`: Traverses and lists files and directories inside an ISO 9660 disc.
- `extract <iso> <file> <dest>`: Extracts any file directly from an ISO image.
- `boot-files <iso>`: Locates distribution boot files and recommended kernel parameters.
- `extract-kernel <iso> [dest]`: Extracts AND decompresses the boot kernel to a raw ARM64 Image.
- `create <path> <size>`: Creates sparse raw disk images (e.g., `10G`, `512M`).
- `convert <source> <dest>`: Converts/copies disk images to raw disk images.

### 3. `check` (`cmd/check`)
Offline test suite with 149 passing verification checks covering all device models (VirtIO, PCI, NVMe, xHCI, USB storage), FDT and ACPI generation, network packet parsers, ISO 9660 directory structures, and kernel decompressors without requiring hypervisor permissions.

### 4. `boot-test` (`cmd/boot-test`)
Live hypervisor integration test suite executing bare-metal machine cycles, direct kernel boots and a UEFI boot of a Windows ARM64 ISO against Apple's `Hypervisor.framework`. `./boot-test pmu` checks that PMU registers work under the in-kernel GIC; `./boot-test trace-late` traces xHCI and SCSI traffic once Windows has taken over.

---

## 4. Quick Start

### Build and Codesign

On macOS, binaries using `Hypervisor.framework` require the `com.apple.security.hypervisor` entitlement:

```bash
# 1. Run offline verification suite (149 checks)
vsc run ./cmd/check

# 2. Build and sign the VM runner
vsc build -o ./vm-run ./cmd/vm-run
codesign --entitlements ./entitlements.plist --force -s - ./vm-run

# 3. Build the disk utility
vsc build -o ./disk-tool ./cmd/disk
```

### Running Virtual Machines

```bash
# Direct boot an Alpine Linux microVM (headless terminal mode)
./vm-run --kernel testdata/Image --initrd testdata/initramfs-virt

# Direct one-click boot a Debian Installer ISO (text mode)
./vm-run --iso testdata/debian/mini.iso

# Direct one-click boot an Ubuntu Desktop Live ISO with graphical window
./vm-run --iso ubuntu-26.04.1-desktop-arm64.iso --display

# Boot with custom memory, vCPUs, and an attached secondary disk
./vm-run --iso installer.iso --memory 2048 --cpus 2 --disk data.raw --display

# Save a screenshot of the guest display to PNG after booting
./vm-run --iso testdata/debian/mini.iso --display --screenshot installer.png --timeout 5

# Install Windows 11 ARM64 from its ISO onto a 64 GiB NVMe disk (created if missing)
./vm-run --iso Windows11_Client_arm64_en-us_26300_9457.iso --disk windows.raw
```

### Windows ARM64

A Windows ARM64 ISO is recognised by its volume ID and boots under UEFI
(EDK2's `edk2-aarch64-code.fd`, from Homebrew's `qemu` or `--firmware`)
on hardware Windows drives with inbox drivers:

| Guest sees | Device | Windows driver |
| :--- | :--- | :--- |
| the ISO | USB CD-ROM on xHCI (bulk-only, SCSI/MMC) | `usbxhci`, `usbstor`, `cdrom` |
| the disk | NVMe namespace | `stornvme` |
| keyboard and mouse | USB HID keyboard and absolute tablet | `kbdhid`, `mouhid` |
| the screen | ramfb, as UEFI GOP | Basic Display |
| interrupts, CPUs, timers | GICv3 with an MSI frame (MSI-X for NVMe and xHCI), PSCI over HVC, generic timer, via ACPI | inbox HAL |

The EFI variable store is saved beside the disk (`windows.raw.efivars`)
when the VM exits, so the boot entries Setup writes survive. Cmd+Q
closes the VM; Cmd on its own is the Windows key. There is no network
yet: Windows has no inbox driver for virtio-net.

### Inspecting and Extracting ISO Images

```bash
# Inspect ISO volume descriptor and El Torito bootability
./disk-tool info testdata/debian/mini.iso

# List files in the root or a subfolder of an ISO
./disk-tool list-iso testdata/debian/mini.iso
./disk-tool list-iso ubuntu-26.04.1-desktop-arm64.iso casper

# Automatically detect kernel, initramfs, and recommended cmdline
./disk-tool boot-files testdata/debian/mini.iso

# Extract and decompress an EFI zboot or Gzip kernel to a bootable ARM64 Image
./disk-tool extract-kernel ubuntu-26.04.1-desktop-arm64.iso ./Image
```

---

## 5. Using the `vm` Package in Vertex Code

```vertex
import "fs"
import "vm"
import "vm/boot"
import "vm/disk"

func runMyVm() async throws {
    // 1. Configure the virtual machine
    var cfg = vm.Config(cpus: 2, memory: 1024 << 20) // 2 vCPUs, 1 GiB RAM
    
    // Load and unpack kernel (supports raw ARM64 Image, gzip, and EFI zboot)
    let rawKernel = try fs.Open(fs.Path("Image")).ReadToEnd()
    let kernel = try await boot.UnpackKernel(rawKernel)
    let initrd = try? fs.Open(fs.Path("initrd")).ReadToEnd()

    cfg.Boot = .linux(
        kernel: kernel,
        initrd: initrd,
        cmdline: "console=ttyAMA0 earlycon=pl011,0x09000000 reboot=k panic=-1"
    )

    // 2. Attach storage, network, and display
    let diskImg = try await vm.OpenDisk(fs.Path("rootfs.raw"))
    cfg.Storage.append(.disk(diskImg))
    cfg.Network.append(.nat())
    cfg.Display = .custom(width: 1024, height: 768)

    // 3. Create, start, and await exit
    let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
    defer { machine.Close() }

    try machine.Start()
    let status = try await machine.Wait()
    print("VM finished execution: \(status)")
}
```

---

## 6. Project Roadmap & TODOs

The core microVM engine, direct Linux boot, ISO auto-boot, user-space networking, VirtIO input/display, and disk subsystems are fully functional. The following items represent planned architectural enhancements:

- [ ] **Shared Host Folders (`virtio-fs` or 9P2000.L)**
  - Implement a VirtIO shared filesystem gateway (`--share <host_dir>`) allowing guest Linux to mount host macOS folders without network overhead.
- [x] **PCIe ECAM Root Complex Integration (`vm/pci`)**
- [x] **UEFI Firmware Boot Path**: EDK2 in two flash banks, ACPI through fw_cfg's table loader, ramfb.
- [x] **NVMe Controller Model (`vm/nvme`)**
- [x] **USB xHCI Controller (`vm/usb`)**
- [ ] **A NIC Windows drives inbox** (e1000e, or the like), for networking in Windows guests.
- [x] **MSI-X for PCI devices**, through the in-kernel GIC's MSI frame (described in the MADT; there is no ITS).
- [ ] **x86_64 Hypervisor Wiring**
  - Complete KVM and WHP in-kernel LAPIC/IOAPIC setup and PVH 32-bit entry mode for AMD64 host environments.
- [ ] **Dynamic Display Resize Notifications**
  - Connect host window resize events to guest display resolution renegotiation via VirtIO GPU or EDID update notifications.
