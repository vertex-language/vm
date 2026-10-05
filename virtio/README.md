# vm/virtio

VirtIO 1.2: the queues, both transports, and the devices.

| File | What it is |
| :--- | :--- |
| `device.vs` | `Device`, `Notifier`, device IDs, feature and status bits |
| `queue.vs` | split virtqueues over `device.GuestMemory`: `Pop`, `Push`, indirect descriptors, event index |
| `packed.vs` | packed virtqueues (to do) |
| `mmio.vs` | `MmioTransport`: VirtIO over MMIO version 2, for the micro platform |
| `pci.vs` | `PciTransport`: VirtIO over PCI with MSI-X, for the standard platform |
| `block.vs` | `Block`: virtio-blk over any `disk.Image` |
| `net.vs` | `Net`: virtio-net over any `ether.Port` (`net/nat`, `net/tap`) |
| `console.vs` | `Console`: hvc0 over `io` streams |
| `rng.vs` `vsock.vs` `balloon.vs` `input.vs` | entropy, host↔guest sockets, memory reclaim, evdev input |

| ID | Device | Status |
| :--- | :--- | :--- |
| 1 | net | ✓ |
| 2 | block | ✓ |
| 3 | console | ✓ |
| 4 | entropy | ✓ |
| 5 | balloon | partial |
| 16 | gpu | later |
| 18 | input | partial |
| 19 | vsock | partial |
| 26 | fs | later, over `fs/fuse` |

A device is written once, against `Device`. `vm` chooses the transport.
Register access runs on the vCPU thread under the transport's lock. A kick
calls `Notified`, which starts a task and returns.
