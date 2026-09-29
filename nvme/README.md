# vm/nvme

An NVMe 1.4 controller over PCI: `Controller` (registers, the admin queue,
MSI-X) and one `Namespace` per `disk.Image`.

NVMe is the one disk every modern guest *and* its firmware drives inbox:
Windows (`stornvme`), Linux, the BSDs and UEFI (`NvmExpressDxe`). It's what
lets Windows install with no extra drivers, so it's the default disk for
`Guest.windows` on the standard profile.

Status: registers, doorbells, queue pairs, read/write/flush with PRPs.
Identify, queue creation and deallocate are marked `TODO(P4)`.
