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

### Kernel Format Detection & Automatic Unpacking
Modern distribution kernels (e.g. Ubuntu, Debian, Fedora, Arch) are often distributed as compressed binaries or EFI PE executables:
- **Raw ARM64 Image**: Magic `0x644d5241` ("ARMd") at offset 0x38. Loaded directly without modification.
- **EFI zboot PE Images**: Portable Executable headers containing a `.linux` section with `zimg` header. Automatically parses PE sections, locates the payload offset, and decompresses Zstandard (`zstd`) or Gzip (`gzip`) streams into a raw ARM64 Image in memory.
- **Gzip-compressed Images**: RFC 1952 streams (`0x1f 0x8b`), automatically decompressed via Vertex standard `compress/gzip`.
- `boot.UnpackKernel(bytes)` handles format detection and unpacking automatically for `vm-run` and `cmd/disk`.

Firmware is a guest artifact you supply, like a kernel: `edk2-aarch64-code.fd`
or `OVMF_CODE.fd` from your distribution or Homebrew's `qemu` share. It is
never vendored here.
