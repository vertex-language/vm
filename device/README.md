# vm/device

The contract every device model is written against:

- **`GuestMemory`**: the machine's RAM by guest-physical address. It's
  bounds-checked, with atomic loads and stores for ring indices.
- **`Mmio`** / **`Pio`**: register access. It runs on a vCPU thread,
  synchronously.
- **`Bus`**: a sorted range table. The vCPU loop looks devices up in it on
  every exit.
- **`Irq`** / **`Msi`**: wired lines and message-signalled interrupts.

Devices never import `vm` or `vm/hypervisor`. In `cmd/check`, a
`GuestMemory` over an ordinary buffer and a `RecordingIrq` are a whole
machine as far as a device can tell.

**Threading.** Register access takes the device's `sync.Mutex`, changes
state and returns. A doorbell starts a task that does the I/O, writes the
completion into guest memory and raises the interrupt. The vCPU is back in
the guest before the I/O finishes.
