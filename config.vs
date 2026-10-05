package vm

import (
    "vm/disk"
    "net/ether"
    "net/nat"
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
    /// Android on the emulator's goldfish devices ("ranchu"): a
    /// goldfish-fb screen and goldfish-events input instead of the VirtIO ones.
    case android
    case other
}

public enum ConsoleRole {
    case stdio
    case none
}

public struct DisplayRole {
    public let Enabled: bool
    public let Width: int
    public let Height: int

    public init(enabled: bool, width: int = 800, height: int = 600) {
        self.Enabled = enabled
        self.Width = width
        self.Height = height
    }

    public static let none = DisplayRole(enabled: false, width: 0, height: 0)
    public static let framebuffer = DisplayRole(enabled: true, width: 800, height: 600)

    public static func custom(width: int, height: int) -> DisplayRole {
        DisplayRole(enabled: true, width: width, height: height)
    }
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

    /// The internet through the host: a net/nat Gateway on `config`'s
    /// private network (192.168.127.0/24 unless told otherwise).
    public static func nat(_ config: nat.Config = .default) -> NetworkRole {
        NetworkRole(port: nat.Gateway(config), isNat: true)
    }

    public static func port(_ p: any ether.Port) -> NetworkRole {
        NetworkRole(port: p, isNat: false)
    }
}

/// A TPM 2.0 for the guest.
public enum TpmRole {
    /// swtpm, keeping the TPM's state (its seeds, NV, keys) in `stateDir`.
    case swtpm(stateDir: string)
}

/// A filesystem Android 8+ mounts in its first stage, before any fstab
/// file is readable: given to it in the device tree, under
/// /firmware/android/fstab, as the Android emulator does.
public struct AndroidMount {
    /// The mount point without its slash: "system", "vendor".
    public let Name: string
    public let Device: string
    public let FsType: string
    public let MountFlags: string
    public let FsmgrFlags: string

    public init(name: string, device: string, fsType: string, mountFlags: string, fsmgrFlags: string) {
        Name = name
        Device = device
        FsType = fsType
        MountFlags = mountFlags
        FsmgrFlags = fsmgrFlags
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
    /// A TPM 2.0 (UEFI boots only: firmware and OS find it by DTB and ACPI).
    public var Tpm: TpmRole? = nil
    /// VirtIO MMIO devices speak version 1 (legacy) rather than 2: for
    /// Linux before 4.0, whose virtio_mmio knows no other (Android 5–7's
    /// emulator kernels). See boot.LinuxVersion.
    public var LegacyVirtio: bool = false
    /// Android's first-stage mounts, for its device tree (empty for other guests).
    public var AndroidMounts: [AndroidMount] = []
    /// Android 10+: the touchscreen and keys are virtio-input (the
    /// emulator's "virtio_input_multi_touch_1"), not goldfish-events,
    /// which its kernels no longer drive.
    public var AndroidVirtioInput: bool = false

    public init(cpus: int = 1, memory: uint64 = 1024 << 20) {
        Cpus = cpus
        Memory = memory
        Profile = .micro
        Guest = .linux
        Boot = nil
    }
}
