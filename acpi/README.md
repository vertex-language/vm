# vm/acpi

ACPI tables for guests, on arm64 and amd64. The tables are hardware-reduced
(no PM1, SCI or legacy timers), and a Generic Event Device carries the
power button.

| Table | Builder | For |
| :--- | :--- | :--- |
| RSDP | `Rsdp(xsdt:)` | both |
| XSDT | `Xsdt(_:)` | both |
| FADT | `Fadt(_:)` | both: `HW_REDUCED_ACPI`; `ARM_BOOT_ARCH` = PSCI over HVC on arm64 |
| MADT | `Madt.Build(Amd64 / Arm64)` | LAPIC + IOAPIC, or GICC + GICD + GICR + ITS |
| GTDT | `Gtdt()` | arm64 timers |
| IORT | `Iort()` | arm64 MSI routing (to do) |
| MCFG | `Mcfg(ecam:)` | PCIe ECAM |
| SPCR | `Spcr(...)` | the serial console (Windows EMS, Linux earlycon) |
| DSDT | `Dsdt(_:)` + `Aml`, `Resources` | the devices: UARTs, RTC, PCI root, GED, virtio-mmio |

Everything is built in Vertex. `iasl` is only used in `cmd/check`, as a
cross-check where it's installed.
