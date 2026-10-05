# vm/windows

Sets up Windows ARM64 guests: finds UEFI firmware, builds the ACPI tables, recognizes Windows install media, and produces a ready VM configuration with an unattended-setup file.

```vertex
import "vm/windows"
```

## Types

- **`WindowsError`** (enum)
- **`Firmware`** (struct): UEFI firmware for a Windows guest: its code, the template its variable store starts from, and what it is.
- **`WindowsIsoInfo`** (struct)
- **`LoaderCommandType`** (enum): QemuLoaderCmd: command types for QEMU's ACPI table loader interface.
- **`TableLoader`** (struct): TableLoader builds the 128-byte packed commands for the "etc/table-loader" fw_cfg file.

## Functions

- `func BuildWindowsAcpi(vcpus: int, virtioCount: int) -> acpi.Payload`: Builds ACPI payload configured for Windows ARM64.
- `func InstallAcpiTables(fwcfg: boot.FwCfg, payload: acpi.Payload)`: Registers the generated ACPI tables with fw_cfg so EDK2 installs them.
- `func FindFirmware(customCodePath: string? = nil, customVarsPath: string? = nil) throws -> Firmware`: Finds UEFI firmware for a Windows guest: `customCodePath` if given (with `customVarsPath` as its template), else the Secure Boot firmware in firmware/, else QEMU's (Secure Boot off).
- `func ConfigureVm( isoPath: string, vcpus: int = 4, memoryMiB: int = 4096, targetDisk: (any disk.Image)? = nil, firmware: Firmware, savedVars: [uint8]? = nil, tpmStateDir: string? = nil ) async throws -> vm.Config`: Automatically creates a complete VM configuration tailored for Windows ARM64.
- `func DetectIso(_ path: string) throws -> WindowsIsoInfo?`: Detects whether an ISO image at the given path is a Windows ARM64 installation media.
- `func GenerateAutoUnattendXml() -> string`: Generates an unattended setup configuration (autounattend.xml) that automatically bypasses TPM 2.0, Secure Boot, CPU, and RAM checks for Windows 11 virtual machines.

Part of the [`vm`](https://github.com/vertex-language/vm) repository.
