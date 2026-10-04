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
| **`vm/tpm`** | **Production** | TPM 2.0: the TIS / FIFO register interface over MMIO (QEMU's state machine), found by firmware through the DTB (`tcg,tpm-tis-mmio`) and by Windows through ACPI (`MSFT0101` and the `TPM2` table), in front of a `Backend`; today `Swtpm`, the swtpm process over Unix sockets, with its state kept beside the disk. |
| **`vm/android`** | **Working** | Android emulator system images (Google's AOSP builds, no Google services, pulled with [`vmimage`](../vmimage)): reads a bundle's API level, kernel, ramdisk and disk order, and the kernel command line the emulator's "ranchu" board gives. Android 5–7.1 (API 21–25). |
| **`vm/windows`** | **Production** | Windows ARM64 ISO detection, EDK2 firmware lookup, and the machine configuration Windows installs on. |
| **`vm/disk`** | **Production** | Disk backend protocol (`Image`), raw disk driver, pure-Vertex ISO 9660 filesystem parser (`disk/iso.vs` with PVD, El Torito, directory reader, boot file discovery, and chunked extraction), QCOW2 reader (`disk/qcow2`), and VHDX reader (`disk/vhdx`). |

---

## 3. Included CLI Programs

The repository includes five executable tools in `cmd/`:

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
Offline test suite with 185 passing verification checks covering all device models (VirtIO, PCI, NVMe, xHCI, USB storage), FDT and ACPI generation, network packet parsers, ISO 9660 directory structures, and kernel decompressors without requiring hypervisor permissions.

### 4. `boot-test` (`cmd/boot-test`)
Live hypervisor integration test suite executing bare-metal machine cycles, direct kernel boots and a UEFI boot of a Windows ARM64 ISO against Apple's `Hypervisor.framework`. `./boot-test pmu` checks that PMU registers work under the in-kernel GIC; `./boot-test trace-late` traces xHCI and SCSI traffic once Windows has taken over.

---

## 4. Quick Start

### Build and Codesign

On macOS, binaries using `Hypervisor.framework` require the `com.apple.security.hypervisor` entitlement:

```bash
# 1. Run offline verification suite (185 checks)
vsc run ./cmd/check

# 2. Build and sign the VM runner
vsc build -o ./vm-run ./cmd/vm-run
codesign --entitlements ./entitlements.plist --force -s - ./vm-run

# 3. Build the disk utility
vsc build -o ./disk-tool ./cmd/disk
```

### Running Virtual Machines

```bash
# Boot a Linux microVM directly from a kernel and initramfs
./vm-run --kernel testdata/debian/linux --initrd testdata/debian/initrd.gz

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

# Android 5.0 (AOSP, no Google services), from Google's emulator image
vmimage --pull android:5 && vmimage --clone android:5 testdata/android/api21
./vm-run --android testdata/android/api21 --display
```

### Windows ARM64

A Windows ARM64 ISO is recognised by its volume ID and boots under UEFI
with Secure Boot on: the EDK2 build and Microsoft-key variable store in
[`firmware/`](firmware/README.md) (Ubuntu's AAVMF, as libvirt uses), or
`--firmware`; without `firmware/`, Homebrew QEMU's EDK2 with Secure Boot
off. It runs on hardware Windows drives with inbox drivers:

| Guest sees | Device | Windows driver |
| :--- | :--- | :--- |
| the ISO | USB CD-ROM on xHCI (bulk-only, SCSI/MMC) | `usbxhci`, `usbstor`, `cdrom` |
| the disk | NVMe namespace | `stornvme` |
| keyboard and mouse | USB HID keyboard and absolute tablet | `kbdhid`, `mouhid` |
| the screen | ramfb, as UEFI GOP | Basic Display |
| TPM 2.0 | TIS over MMIO, backed by swtpm (`brew install swtpm`); state in `windows.raw.tpm/` | `tpm.sys` |
| interrupts, CPUs, timers | GICv3 with an MSI frame (MSI-X for NVMe and xHCI), PSCI over HVC, generic timer, via ACPI | inbox HAL |

The EFI variable store is saved beside the disk (`windows.raw.efivars`)
when the VM exits, so the boot entries Setup writes survive, and the TPM's
state lives in `windows.raw.tpm/`, so the guest sees the same TPM every
boot (`--no-tpm` leaves it out). A variable store is only reused by the
firmware that wrote it (`windows.raw.efivars.firmware` says which), so
switching firmware starts a fresh one with that firmware's keys. Cmd+Q
closes the VM; Cmd on its own is the Windows key. There is no network
yet: Windows has no inbox driver for virtio-net.

### Android

`--android <dir>` boots one of Google's Android emulator system images: plain
AOSP, `eng` builds with no Google services, the smallest 201 MB (Android 5.0,
API 21). [`vmimage`](../vmimage) pulls and checks them (`vmimage --pull
android:5`) and `vmimage --clone android:5 <dir>` makes a directory of the
image's own to boot and change: `kernel-ranchu`, `ramdisk.img`, and the
`system.img`, `cache.img` and `userdata.img` disks.

vm presents the emulator's "ranchu" board, the devices its goldfish kernels
(Linux 3.18 for Android 5–7) drive:

| Guest sees | Device | Notes |
| :--- | :--- | :--- |
| /system, /cache, /data | VirtIO block over MMIO, **version 1 (legacy)** | Linux before 4.0 has no other; chosen when the kernel's version string says so (`Config.LegacyVirtio`) |
| /dev/graphics/fb0 | `goldfish-fb`: RGB565 in guest RAM, flipped by SET_BASE | always present (SurfaceFlinger aborts without one); `--display` shows it, 720×1280 unless `--width`/`--height` |
| touchscreen and keyboard | `goldfish-events`, named `qwerty2` | the image's `qwerty2.idc` makes it a touchscreen; click to touch, right-click or Esc is Back, Home is Home |
| battery | `goldfish-battery` | always full on mains; without it Android 5's BatteryService fails the system server's first start |
| eth0 | VirtIO net (legacy) on vm's NAT | at the emulator's addresses: guest 10.0.2.15, gateway 10.0.2.2, DNS 10.0.2.3 |
| console | PL011 `ttyAMA0` | a shell (`shell@generic_arm64`); `su` for root |
| interrupts | GICv3, every interrupt put in Group 1 before a direct boot | as firmware (or QEMU) would: Linux 3.18 leaves them in Group 0, which the GIC signals as FIQs it never takes |

The emulator hands Android some properties at boot through its qemud
"boot-properties" service; vm has no qemud yet, so it adds them to the
ramdisk's `default.prop` instead (a second cpio archive after the image's,
built in memory; the image is untouched): `dalvik.vm.heapsize` (256 MB; the
runtime's 16 MB default runs the launcher out of memory opening its app
drawer), `ro.sf.lcd_density` (320 for 720 wide) and `qemu.hw.mainkeys=0`
(the Back / Home / Recents bar).

It boots to the launcher in about a minute (software rendering:
`qemu.gles=0`), SELinux permissive. Not yet: DNS and connectivity for apps
(Android 5 gets its default network from the emulator's modem, RIL over a
goldfish pipe; IP works, `su 0 ping 1.1.1.1`), sound, and Android 8 and
later (a vendor partition, verified-boot metadata, and goldfish pipes for
graphics).

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
- [x] **TPM 2.0 (`vm/tpm`)**, on swtpm.
- [ ] **A TPM 2.0 engine of Vertex's own**, behind `tpm.Backend`, so swtpm isn't needed.
- [x] **Secure Boot**: Secure Boot firmware with Microsoft's keys enrolled (`firmware/`).
- [x] **Container images as VMs**: moved to [`container`](../container) (`container run`, `container build`), which owns images-as-containers; `vm` only boots machines.
- [x] **Android 5–7.1 (API 21–25)**: the ranchu board's goldfish screen, input and battery, legacy VirtIO MMIO (`vm/android`, `--android`).
- [ ] **Android: goldfish pipe and qemud**, for the emulator's modem (apps' connectivity and DNS), sensors, and boot properties from the host (today they ride in the ramdisk).
- [ ] **Android 8 and later**: vendor partitions, verified-boot (vbmeta) arguments, VirtIO PCI, gfxstream graphics.
- [ ] **A NIC Windows drives inbox** (e1000e, or the like), for networking in Windows guests.
- [x] **MSI-X for PCI devices**, through the in-kernel GIC's MSI frame (described in the MADT; there is no ITS).
- [ ] **x86_64 Hypervisor Wiring**
  - Complete KVM and WHP in-kernel LAPIC/IOAPIC setup and PVH 32-bit entry mode for AMD64 host environments.
- [ ] **Dynamic Display Resize Notifications**
  - Connect host window resize events to guest display resolution renegotiation via VirtIO GPU or EDID update notifications.
