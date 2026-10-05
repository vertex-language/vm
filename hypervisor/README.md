# vm/hypervisor

The host's hardware virtualization, with nothing on top: a partition of
guest-physical memory, an in-kernel interrupt controller, vCPUs, and the
exits that bring them back.

| Host | Backend | Notes |
| :--- | :--- | :--- |
| macOS, Apple Silicon | Hypervisor.framework (`hv_darwin.cpp`) | macOS 15 for `hv_gic`; one VM per process; binary needs `com.apple.security.hypervisor` |
| Windows x64 | WHP (`hv_windows.cpp`) | "Windows Hypervisor Platform" feature on; LAPIC only, so the IOAPIC is `vm/chipset`'s |
| Linux x64 / arm64 | KVM (`hv_linux.cpp`) | `/dev/kvm` readable; GIC / LAPIC / IOAPIC / PSCI in the kernel |
| Android | `hv_android.cpp` | unsupported: apps can't open `/dev/kvm` |

```vertex
import "vm/hypervisor"

let caps = try hypervisor.Probe()
let p = try hypervisor.Create(vcpus: 1)
defer { p.Close() }
try p.Map(guest: 0x4000_0000, host: ram, count: 64 << 20)
let cpu = try p.CreateVcpu(0)            // on the thread that will run it
switch try cpu.Run() {
case .mmio(let a):
    // a device register; answer a read with cpu.Complete(read:)
case .hypercall(let call):
    // PSCI on arm64
default:
    break
}
```

`Run` blocks its thread. That's deliberate: a vCPU gets a thread of its own
(`sync.Thread`), never a task executor worker. `Kick` gets it back from any
thread.

Most programs want package `vm`, which builds a whole machine on this.
