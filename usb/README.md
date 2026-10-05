# vm/usb

An xHCI controller over PCI, and the USB devices guests drive with inbox
drivers:

| Type | What it is | Why |
| :--- | :--- | :--- |
| `Xhci` | the controller: registers, rings, root-hub ports | inbox in Windows, Linux, the BSDs, UEFI |
| `Keyboard` | a HID boot keyboard | typing in firmware menus and Windows setup |
| `Tablet` | a HID absolute pointer | the guest cursor tracks the host's, with no capture |
| `Storage` | bulk-only mass storage (SCSI) | installer ISOs; Apple's Virtualization.framework attaches them the same way |

Linux guests with a display may use `virtio.Input` instead. Windows has no
inbox driver for it, so Windows gets these.

Status: descriptors and HID reports are done. The xHCI rings and the
bulk-only data phases are marked `TODO(P4)`.
