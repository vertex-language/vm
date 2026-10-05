# firmware

UEFI firmware for arm64 guests, kept here compressed the way QEMU keeps
its EDK2 builds in `pc-bios/`.

| File | What it is |
| :--- | :--- |
| `AAVMF_CODE.secboot.fd.gz` | EDK2 ArmVirtQemu built with Secure Boot (and TPM 2.0): the firmware code, flash bank 0 |
| `AAVMF_VARS.ms.fd.gz` | its variable store with Secure Boot on and Microsoft's keys enrolled: KEK CA 2011 and KEK 2K CA 2023; db Windows Production PCA 2011, Windows UEFI CA 2023, UEFI CA 2011 and 2023 |

Windows 11 checks for Secure Boot, and its boot manager is signed by the
Windows CAs in that db, so a Windows guest boots with Secure Boot on.
`vm-run` copies the variable store beside each disk on first boot.

## Where they come from

Ubuntu's `qemu-efi-aarch64` package, version `2025.11-3ubuntu7.2`:
<http://archive.ubuntu.com/ubuntu/pool/main/e/edk2/qemu-efi-aarch64_2025.11-3ubuntu7.2_all.deb>
(SHA-256 `2f1a0f09769bb336a84aa8f7aa46115da416ad729d4715fa780c61d1bf67550e`),
files `/usr/share/AAVMF/AAVMF_CODE.secboot.fd` and
`/usr/share/AAVMF/AAVMF_VARS.ms.fd`, gzipped unchanged.

| Uncompressed | SHA-256 |
| :--- | :--- |
| `AAVMF_CODE.secboot.fd` | `02b8af5a5a23e66418b8b2fd2d223fa40a9e3eb73c25cdce173cd11aa014cd4b` |
| `AAVMF_VARS.ms.fd` | `a37e222dd324e224b1e1c333a53f2c3b692e3fd21cf856a9bebd6c6114711768` |

To update: download a newer package, extract those two files, gzip them
(`gzip -9`), and update the table above.

## License

EDK2 is BSD-2-Clause-Patent, with the third-party components listed in
`COPYRIGHT.edk2` (the package's copyright file). The enrolled
certificates are Microsoft's public Secure Boot certificates.
