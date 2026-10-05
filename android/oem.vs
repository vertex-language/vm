package android

import (
    "fs"
    "fs/ext4"
    "vm"
    "vm/disk"
)

// Android 9+ has no ramdisk to carry the Ethernet feature file in, so
// vm gives it an /oem partition holding it: a small ext4 made in memory,
// a second partition on the vendor disk (a disk of its own would be
// /dev/block/vdf, which the vendor's fstab hands vold as the SD card),
// mounted by init's first stage from the device tree like /vendor.
// PackageManager reads /oem/etc/permissions, so EthernetService starts
// and makes eth0 the default network, as on Android 5–8.

/// The /oem partition's name, and its file system's size.
let oemPartition = "oem"
let oemSize = 1 << 20

extension Bundle {
    /// Whether this image gets the /oem partition: Android 9+, with Ethernet.
    func hasOem(_ props: BootProperties) -> bool { SystemAsRoot && props.Ethernet }

    /// The slot of the disk holding the vendor partition, which /oem joins.
    var vendorSlot: int? { Disks.firstIndex(where: { $0.Partition == "vendor" }) }

    /// The disks, opened, whole: a GPT disk keeps its partition table, so
    /// the guest's kernel names the partition (PARTNAME), which Android
    /// 8's first stage looks for. For Android 9 with Ethernet, the vendor
    /// disk also holds /oem (`OemFiles`).
    public func OpenDisks(_ props: BootProperties) async throws -> [any disk.Image] {
        var out: [any disk.Image] = []
        for (i, d) in Disks.enumerated() {
            let img = try await vm.OpenDisk(fs.Path(d.Path))
            if i == vendorSlot && hasOem(props) {
                guard let vendor = try await disk.Partitions(img).first(where: { $0.Name == "vendor" }) else {
                    throw AndroidError.notABundle(d.Path + " (no vendor partition)")
                }
                var o = ext4.FormatOptions()
                o.BlockSize = 1024
                o.Label = oemPartition
                o.Files = OemFiles(props)
                let vendorPart: any disk.Image = disk.Slice(img, vendor)   // vsc_TODO #57
                let oem: any disk.Image = disk.MemoryImage(bytes: try ext4.FormatBytes(size: oemSize, o))
                out.append(disk.GptDisk(names: ["vendor", oemPartition], images: [vendorPart, oem]))
            } else {
                out.append(img)
            }
        }
        return out
    }

    /// What init's first stage mounts from the device tree: the image's
    /// own (`EarlyMounts`), and /oem where it has one.
    public func FirstStageMounts(_ props: BootProperties) -> [vm.AndroidMount] {
        guard hasOem(props), let slot = vendorSlot else { return EarlyMounts }
        return EarlyMounts + [vm.AndroidMount(name: oemPartition, device: byName(slot: slot, partition: oemPartition), fsType: "ext4",
                                              mountFlags: "ro,barrier=1", fsmgrFlags: "wait")]
    }
}

/// The files /oem holds.
public func OemFiles(_ props: BootProperties) -> [ext4.File] {
    if !props.Ethernet { return [] }
    return [ext4.File("etc/permissions/android.hardware.ethernet.xml", [uint8](ethernetFeature.utf8))]
}
