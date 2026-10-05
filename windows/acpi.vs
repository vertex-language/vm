package windows

import (
    "vm/acpi"
    "vm/boot"
)

/// Builds ACPI payload configured for Windows ARM64.
public func BuildWindowsAcpi(vcpus: int, virtioCount: int) -> acpi.Payload {
    let cfg = acpi.Arm64Config(
        vcpus: vcpus,
        virtioCount: virtioCount
    )
    return acpi.BuildArm64(cfg)
}

/// Registers the generated ACPI tables with fw_cfg so EDK2 installs them.
public func InstallAcpiTables(fwcfg: boot.FwCfg, payload: acpi.Payload) {
    fwcfg.Add(boot.FwCfg.File(name: "etc/acpi/tables", bytes: payload.Tables))
    fwcfg.Add(boot.FwCfg.File(name: "etc/acpi/rsdp", bytes: payload.Rsdp))
    fwcfg.Add(boot.FwCfg.File(name: "etc/table-loader", bytes: payload.Loader))
}
