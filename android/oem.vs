package android

import (
    "fs"
    "fs/ext4"
    "vm"
    "vm/disk"
)

// Android 9+ has no ramdisk the running system reads to carry the
// Ethernet feature file in, so vm gives it an /oem partition holding it:
// a small ext4 made in memory, another partition on a GPT disk the image
// has — Android 9's vendor disk, Android 10's system disk beside super (a
// disk of its own would be the one the vendor's fstab hands vold as the
// SD card) — mounted by init's first stage: from the device tree like
// /vendor on Android 9, from the ramdisk's fstab on Android 10.
// PackageManager reads /oem/etc/permissions, so EthernetService starts
// and makes eth0 the default network, as on Android 5–8.

/// The /oem partition's name, and its file system's size.
let oemPartition = "oem"
let oemSize = 1 << 20

/// Android 10's first-stage fstab, in its ramdisk, and the line /oem adds to it.
let firstStageFstab = "fstab.ranchu"
let oemFstabLine = "/dev/block/by-name/oem   /oem        ext4    ro,barrier=1     wait,first_stage_mount\n"

extension Bundle {
    /// Whether this image gets the /oem partition: Android 9+, with Ethernet.
    func hasOem(_ props: BootProperties) -> bool { NoRamdiskProperties && props.Ethernet }

    /// The slot of the GPT disk /oem joins: Android 9's vendor, Android 10's system (super).
    var oemSlot: int? { Disks.firstIndex(where: { $0.Partition == (DynamicPartitions ? "super" : "vendor") }) }

    /// The disks, opened, whole: a GPT disk keeps its partition table, so
    /// the guest's kernel names the partition (PARTNAME), which Android
    /// 8's first stage looks for. For Android 9+ with Ethernet, one of
    /// them also holds /oem (`OemFiles`), after its own partitions.
    public func OpenDisks(_ props: BootProperties) async throws -> [any disk.Image] {
        var out: [any disk.Image] = []
        for (i, d) in Disks.enumerated() {
            let img = try await vm.OpenDisk(fs.Path(d.Path))
            if i == oemSlot && hasOem(props) {
                let parts = try await disk.Partitions(img)
                if !parts.contains(where: { $0.Name == d.Partition }) {
                    throw AndroidError.notABundle(d.Path + " (no \(d.Partition ?? "") partition)")
                }
                var names: [string] = []
                var images: [any disk.Image] = []
                for p in parts {
                    names.append(p.Name)
                    images.append(disk.Slice(img, p))
                }
                var o = ext4.FormatOptions()
                o.BlockSize = 1024
                o.Label = oemPartition
                o.Files = OemFiles(props)
                names.append(oemPartition)
                images.append(disk.MemoryImage(bytes: try ext4.FormatBytes(size: oemSize, o)))
                out.append(disk.GptDisk(names: names, images: images))
            } else {
                out.append(img)
            }
        }
        return out
    }

    /// What init's first stage mounts from the device tree: the image's
    /// own (`EarlyMounts`), and Android 9's /oem. (Android 10's first
    /// stage reads its ramdisk's fstab instead: `BootRamdisk`.)
    public func FirstStageMounts(_ props: BootProperties) -> [vm.AndroidMount] {
        guard hasOem(props) && SystemAsRoot, let slot = oemSlot else { return EarlyMounts }
        return EarlyMounts + [vm.AndroidMount(name: oemPartition, device: byName(slot: slot, partition: oemPartition), fsType: "ext4",
                                              mountFlags: "ro,barrier=1", fsmgrFlags: "wait")]
    }
}

/// The files /oem holds.
public func OemFiles(_ props: BootProperties) -> [ext4.File] {
    if !props.Ethernet { return [] }
    return [ext4.File("etc/permissions/android.hardware.ethernet.xml", [uint8](ethernetFeature.utf8))]
}
