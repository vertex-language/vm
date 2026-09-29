# vm/boot

Getting a guest from reset to its OS. There are two paths.

**Direct kernel boot** (the micro profile, and quick Linux on standard):

| Loader | Kernel | Entry |
| :--- | :--- | :--- |
| `LinuxArm64` | arm64 `Image` | `pc` = image, `x0` = device tree, EL1h, DAIF masked |
| `Pvh` | ELF with `XEN_ELFNOTE_PHYS32_ENTRY` (Linux `vmlinux`, FreeBSD) | 32-bit protected mode, paging off, `ebx` = `hvm_start_info` |
| `BzImage` | x86 `bzImage` (boot protocol ≥ 2.12) | 64-bit, `rsi` = `boot_params` (to do) |

**UEFI firmware** (the standard profile: Windows, distro installers, the
BSDs):

- `Efi` / `EfiBoot`: a firmware image and a variable store.
- `Pflash`: CFI flash banks, the firmware code and its variables.
- `FwCfg`: the file directory stock EDK2 reads ACPI tables and boot order
  from.

Loaders parse bytes and return a `Plan`: what goes where, and the entry
state. `vm` carries it out. No loader touches a vCPU, so all of them run in
`cmd/check`.

Firmware is a guest artifact you supply, like a kernel: `edk2-aarch64-code.fd`
or `OVMF_CODE.fd` from your distribution or Homebrew's `qemu` share. It is
never vendored here.
