# vm/chipset

The small fixed devices:

| Type | Part | Where |
| :--- | :--- | :--- |
| `Ns16550` | 16550A UART | amd64 COM1 (0x3f8, IRQ 4), or MMIO |
| `Pl011` | Arm PL011 UART | arm64 console; SPCR for Windows on ARM |
| `Cmos` | MC146818 RTC | amd64, ports 0x70–0x71; UTC or local time |
| `Pl031` | Arm PL031 RTC | arm64; UTC or local time |
| `IoApic` | 82093AA IOAPIC | amd64 where the hypervisor has none (WHP) |
| `Ged` | ACPI Generic Event Device | power button, S5 and reset on hardware-reduced ACPI |

Files are named for the part, so every model runs in `cmd/check` on any
host. Only `vm`'s `platform_arm64.vs` / `platform_amd64.vs` decide which ones
a machine gets.
