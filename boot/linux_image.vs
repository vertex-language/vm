package boot

import (
    "encoding/binary"
    "vm/device"
)

/// The arm64 Linux Image header (Documentation/arch/arm64/booting.rst).
public struct ImageHeader {
    public let TextOffset: uint64
    public let ImageSize: uint64
    public let Flags: uint64
}

let arm64Magic: uint32 = 0x644d_5241   // "ARM\x64" at offset 0x38

public func ParseImageHeader(_ kernel: [uint8]) throws -> ImageHeader {
    if kernel.count < 64 || binary.LittleEndian.Uint32(kernel, from: 0x38) != arm64Magic {
        throw BootError.badImage("no arm64 Image magic")
    }
    var size = binary.LittleEndian.Uint64(kernel, from: 16)
    if size == 0 {
        size = uint64(kernel.count)   // kernels before 3.17
    }
    return ImageHeader(TextOffset: binary.LittleEndian.Uint64(kernel, from: 8), ImageSize: size,
                       Flags: binary.LittleEndian.Uint64(kernel, from: 24))
}

/// Plans an arm64 Linux boot into RAM at `ram`: the kernel at a 2 MiB
/// boundary plus text_offset, the initrd after it, and the device tree at
/// the top of the first 1 GiB (or of RAM, if smaller), 2 MiB aligned, as
/// booting.rst asks.
public func LinuxArm64(kernel: [uint8], initrd: [uint8]?, cmdline: string, ram: device.Range) throws -> Plan {
    let h = try ParseImageHeader(kernel)
    let kernelAt = alignUp(ram.Base, 2 << 20) + h.TextOffset
    var p = Plan()
    p.Cmdline = cmdline
    p.Loads.append(Load(Address: device.GuestAddress(kernelAt), Bytes: kernel))
    var end = kernelAt + h.ImageSize
    if let rd = initrd {
        let at = alignUp(end, 2 << 20)
        p.Loads.append(Load(Address: device.GuestAddress(at), Bytes: rd))
        p.Initrd = device.Range(base: at, count: uint64(rd.count))
        end = at + uint64(rd.count)
    }
    let dtbAt = alignUp(end, 2 << 20)
    if dtbAt + (2 << 20) > ram.End {
        throw BootError.tooBig("kernel, initrd and device tree")
    }
    p.DeviceTree = device.GuestAddress(dtbAt)
    p.Entry = .arm64(pc: kernelAt, x0: dtbAt)
    return p
}

/// The version an uncompressed Linux kernel announces ("Linux version
/// 3.18.91+ (…)"), as (major, minor), or nil where it says none.
public func LinuxVersion(_ kernel: [uint8]) -> (int, int)? {
    let key = [uint8]("Linux version ".utf8)
    var i = 0
    let limit = kernel.count - key.count - 8
    while i < limit {
        if kernel[i] == key[0] {
            var match = true
            for k in 1..<key.count where kernel[i + k] != key[k] {
                match = false
                break
            }
            if match {
                var j = i + key.count
                var nums: [int] = [0, 0]
                for part in 0..<2 {
                    var digits = 0
                    while j < kernel.count && kernel[j] >= 0x30 && kernel[j] <= 0x39 && digits < 4 {
                        nums[part] = nums[part] * 10 + int(kernel[j] - 0x30)
                        j += 1
                        digits += 1
                    }
                    if digits == 0 { break }
                    if part == 0 {
                        if j >= kernel.count || kernel[j] != 0x2e { break }
                        j += 1
                    } else {
                        return (nums[0], nums[1])
                    }
                }
            }
        }
        i += 1
    }
    return nil
}
