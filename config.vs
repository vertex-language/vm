package vm

import (
    "vm/disk"
    "net/ether"
)

/// The platform profile determining bus topology and device standards.
public enum Profile {
    /// Linux microVM: direct kernel boot, VirtIO over MMIO, FDT or minimal ACPI.
    case micro
    /// Standard machine: PCIe hierarchy, ACPI, UEFI or direct boot.
    case standard
}

/// How the guest boots from reset.
public enum Boot {
    /// Direct kernel boot: arm64 Image, PVH ELF, or bzImage.
    case linux(kernel: [uint8], initrd: [uint8]? = nil, cmdline: string = "")
    /// UEFI firmware image with optional NVRAM variable store.
    case efi(firmware: [uint8], vars: [uint8]? = nil)
}

/// The guest OS family, used to configure sensible hardware defaults.
public enum Guest {
    case linux
    case windows
    case bsd
    case other
}

public enum ConsoleRole {
    case stdio
    case none
}

public enum DisplayRole {
    case framebuffer
    case none
}

public struct StorageRole {
    public let Image: any disk.Image
    public let IsInstaller: bool

    public init(image: any disk.Image, isInstaller: bool = false) {
        self.Image = image
        self.IsInstaller = isInstaller
    }

    public static func disk(_ img: any disk.Image) -> StorageRole {
        StorageRole(image: img, isInstaller: false)
    }

    public static func installer(_ img: any disk.Image) -> StorageRole {
        StorageRole(image: img, isInstaller: true)
    }
}

public struct NetworkRole {
    public let Port: any ether.Port
    public let IsNat: bool

    public init(port: any ether.Port, isNat: bool = false) {
        self.Port = port
        self.IsNat = isNat
    }

    public static func nat() -> NetworkRole {
        NetworkRole(port: ether.LoopbackPort(), isNat: true)
    }

    public static func port(_ p: any ether.Port) -> NetworkRole {
        NetworkRole(port: p, isNat: false)
    }
}

/// Virtual machine configuration by role.
public struct Config {
    public var Cpus: int
    public var Memory: uint64
    public var Profile: Profile
    public var Guest: Guest
    public var Boot: Boot?
    public var Storage: [StorageRole] = []
    public var Network: [NetworkRole] = []
    public var Console: ConsoleRole = .stdio
    public var Display: DisplayRole = .none

    public init(cpus: int = 1, memory: uint64 = 1024 << 20) {
        Cpus = cpus
        Memory = memory
        Profile = .micro
        Guest = .linux
        Boot = nil
    }
}
