# `vm`: Virtual Machines in Vertex

Virtual machines running directly on the host OS's native hypervisor:
- **macOS (Apple Silicon)**: `Hypervisor.framework` (arm64, in-kernel GICv3 via `hv_gic` on macOS 15+)
- **Windows**: Windows Hypervisor Platform (`WinHvPlatform`)
- **Linux**: `/dev/kvm`

Zero instruction emulation. Zero QEMU or libvirt dependencies. 100% native execution where the guest architecture matches the host.

---

## 1. Architecture Overview

```
 user program     │ import "vm"
                  │ let machine = try vm.Create(cfg); try machine.Start(); await machine.Wait()
══════════════════╪═════════════════════════════════════════════════════════════════════════════
 vm               │ Config by ROLE (Storage, Network, Console, Display, Input)
                  │ Machine lifecycle · platform profiles (.micro / .standard) · guest RAM
                  │ dedicated vCPU OS threads · PSCI handler
──────────────────┼─────────────────────────────────────────────────────────────────────────────
 devices, by spec │ vm/virtio   vm/nvme   vm/usb   vm/chipset   vm/display
 boot             │ vm/boot     Linux direct (arm64 Image, bzImage, PVH) · UEFI (pflash, fw_cfg)
 description      │ vm/acpi     vm/pci   (+ encoding/fdt)
 storage          │ vm/disk     vm/disk/qcow2   vm/disk/vhdx
──────────────────┼─────────────────────────────────────────────────────────────────────────────
 contract         │ vm/device   GuestMemory · Mmio / Pio · Bus · Irq / Msi
══════════════════╪═════════════════════════════════════════════════════════════════════════════
 vm/hypervisor    │ Partition · Vcpu · Exit · Capabilities (C++ interop)
                  │ macOS: hv_darwin.cpp  ·  Windows: hv_windows.cpp  ·  Linux: hv_linux.cpp
══════════════════╪═════════════════════════════════════════════════════════════════════════════
 host kernel      │ Apple Hypervisor (EL2) · Hyper-V · KVM
```

---

## 2. Package Index

| Package | Purpose |
| :--- | :--- |
| **`vm`** | Top-level Machine lifecycle (`Create`, `Start`, `Wait`, `Terminate`, `Close`), Config, guest RAM, wiring. |
| **`vm/hypervisor`** | Partition, Vcpu, memory mapping, exits, and native platform hypervisor bridge. |
| **`vm/device`** | `GuestMemory`, `Mmio`, `Pio`, `MmioBus`, `PioBus`, `Irq`, `Msi`. |
| **`vm/boot`** | Boot protocols: Linux arm64 `Image`, `bzImage`, PVH ELF, UEFI pflash/vars, fw_cfg. |
| **`vm/virtio`** | VirtIO 1.2 split & packed queues, MMIO and PCI transports, block, net, console, rng, vsock, balloon, input. |
| **`vm/chipset`** | Arm PL011 UART (`ttyAMA0`), Arm PL031 RTC, 16550 UART, CMOS RTC, IOAPIC, ACPI GED. |
| **`vm/pci`** | PCIe ECAM root complex, config space, BARs, MSI-X, `Function` protocol. |
| **`vm/acpi`** | Hardware-reduced ACPI tables (FADT, MADT, GTDT, IORT, MCFG, SPCR) and AML builder. |
| **`vm/nvme`** | NVMe 1.4 controller, admin & I/O queue pairs, PRP/SGL walking, namespace over `disk.Image`. |
| **`vm/usb`** | xHCI controller, bulk-only mass storage (ISOs), HID keyboard and tablet. |
| **`vm/display`** | Framebuffer interface and firmware `ramfb`. |
| **`vm/disk`** | `Image` protocol, raw sparse files, and subpackages `qcow2` and `vhdx`. |

---

## 3. Quick Start

### Prerequisites
- macOS Apple Silicon (macOS 15+ recommended for in-kernel GICv3)
- Vertex compiler `vsc`
- `com.apple.security.hypervisor` entitlement (provided in `entitlements.plist`)

### 1. Run Offline Checks
The offline test suite validates device models, queue descriptors, boot headers, and Device Tree / ACPI emission without requiring hypervisor privileges:
```bash
vsc run ./cmd/check
```

### 2. Run Hypervisor Boot Tests
Builds and executes both synthetic bare-metal guest tests and full Linux kernel boot tests:
```bash
vsc build -o ./boot-test ./cmd/boot-test
codesign --entitlements ./entitlements.plist --force -s - ./boot-test
./boot-test
```

### 3. Interactive Linux VM Runner (`vm-run`)
Launch an interactive Alpine Linux microVM with terminal console and optional disk image:
```bash
vsc build -o ./vm-run ./cmd/vm-run
codesign --entitlements ./entitlements.plist --force -s - ./vm-run

# Boot Alpine Linux microVM
./vm-run --kernel testdata/Image --initrd testdata/initramfs-virt

# Boot with an attached VirtIO disk
./vm-run --kernel testdata/Image --initrd testdata/initramfs-virt --disk my_disk.raw
```

### 4. Disk Utility (`cmd/disk`)
Manage disk images (raw, qcow2, vhdx):
```bash
# Show image details
vsc run ./cmd/disk -- info my_disk.raw

# Create a new raw disk image
vsc run ./cmd/disk -- create my_disk.raw 10G

# Convert/copy an image
vsc run ./cmd/disk -- convert source.qcow2 target.raw
```

---

## 4. Example: Launching a Linux microVM in Vertex

```swift
import "fs"
import "vm"
import "vm/disk"

// 1. Configure the virtual machine
var cfg = vm.Config(cpus: 2, memory: 1024 << 20) // 2 vCPUs, 1 GiB RAM
cfg.Boot = .linux(
    kernel: try fs.Open("testdata/Image").ReadToEnd(),
    initrd: try fs.Open("testdata/initramfs-virt").ReadToEnd(),
    cmdline: "console=ttyAMA0 earlycon=pl011,0x09000000 reboot=k panic=-1"
)

// 2. Attach optional storage and network
let diskImg = try await vm.OpenDisk(fs.Path("disks/rootfs.raw"))
cfg.Storage.append(.disk(diskImg))
cfg.Network.append(.nat())

// 3. Create, start, and await exit
let machine = try vm.Create(cfg, consoleWriter: vm.StdioWriter())
defer { machine.Close() }

try machine.Start()
let status = try await machine.Wait()
print("VM exited with status: \(status)")
```

---

## 5. License

MIT
