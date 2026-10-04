package chipset

import "vm/device"

/// The Android emulator's battery ("generic,goldfish-battery"): a
/// power_supply "battery" and "ac" for the guest's healthd, here always
/// full and on mains power. Without one, Android 5's BatteryService finds
/// no battery and the system server fails its first start.
public final class GoldfishBattery: device.Mmio {
    public static let Size: uint64 = 0x1000

    // Registers (drivers/power/goldfish_battery.c).
    static let intStatus: uint64 = 0x00
    static let intEnable: uint64 = 0x04
    static let acOnline: uint64 = 0x08
    static let status: uint64 = 0x0c
    static let health: uint64 = 0x10
    static let present: uint64 = 0x14
    static let capacity: uint64 = 0x18
    static let voltage: uint64 = 0x1c
    static let temp: uint64 = 0x20
    static let chargeCounter: uint64 = 0x24
    static let voltageMax: uint64 = 0x28
    static let currentMax: uint64 = 0x2c
    static let currentNow: uint64 = 0x30
    static let currentAvg: uint64 = 0x34
    static let chargeFullUah: uint64 = 0x38
    static let cycleCount: uint64 = 0x40

    /// 0–100.
    public var Capacity: int = 100

    public init() {}

    public func Read(offset: uint64, size: uint8) -> uint64 {
        switch offset {
        case GoldfishBattery.acOnline: return 1
        case GoldfishBattery.status: return Capacity >= 100 ? 4 : 1   // POWER_SUPPLY_STATUS_FULL / _CHARGING
        case GoldfishBattery.health: return 1                         // POWER_SUPPLY_HEALTH_GOOD
        case GoldfishBattery.present: return 1
        case GoldfishBattery.capacity: return uint64(Capacity)
        case GoldfishBattery.voltage: return 4_200_000                // µV
        case GoldfishBattery.temp: return 250                         // tenths of °C
        case GoldfishBattery.chargeCounter: return 10_000             // µAh
        case GoldfishBattery.voltageMax: return 5_000_000
        case GoldfishBattery.currentMax: return 1_500_000
        case GoldfishBattery.chargeFullUah: return 3_000_000
        default: return 0
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {}
}
