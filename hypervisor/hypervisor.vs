// Package hypervisor is the host's hardware virtualization: a partition of
// guest-physical memory, the vCPUs that run in it, and why they stop.
//
// It knows nothing about devices, disks or boot protocols; that's package
// vm and the packages beside it. Most programs import "vm" and never this.
package hypervisor

/// The architecture guests run as. It is always the host's: nothing here
/// emulates instructions.
public enum Arch { case arm64, amd64 }

/// What this host's hypervisor can do. Callers branch on these, never on
/// the platform.
public struct Capabilities {
    public let Arch: Arch
    public let MaxVcpus: int
    /// The interrupt controller runs in the host kernel: KVM (GIC or
    /// LAPIC+IOAPIC), HVF (GICv3, macOS 15). WHP has the LAPIC only, so
    /// this is false there and vm adds an IOAPIC of its own.
    public let InKernelIrqChip: bool
    /// Queue doorbells can be delivered without an exit to the VMM (KVM
    /// ioeventfd, WHP doorbell events).
    public let Doorbells: bool
    /// Hyper-V enlightenments can be offered to the guest.
    public let HyperV: bool
    public let DirtyLogging: bool
    /// How many partitions one process may hold: 1 on macOS.
    public let PartitionsPerProcess: int
    public let PhysicalAddressBits: int
}

/// Which accesses a memory mapping allows.
public struct Access {
    public var Read: bool
    public var Write: bool
    public var Execute: bool

    public init(read: bool = true, write: bool = true, execute: bool = true) {
        Read = read
        Write = write
        Execute = execute
    }

    public static let all = Access()
    public static let readOnly = Access(write: false)

    var bits: int32 {
        var b: int32 = 0
        if Read { b |= AccessBit.read }
        if Write { b |= AccessBit.write }
        if Execute { b |= AccessBit.execute }
        return b
    }
}

/// Asks the host what it has. Throws `unsupported` or `denied` when there's
/// no hypervisor this process can use, which is the check to run first.
public func Probe() throws -> Capabilities {
    var w = [uint64](repeating: 0, count: int(ProbeWord.count))
    let rc = w.withUnsafeMutableBufferPointer { hvProbe($0.baseAddress, ProbeWord.count) }
    try check(rc, "probing the hypervisor")
    return Capabilities(
        Arch: w[int(ProbeWord.arch)] == uint64(ArchCode.arm64) ? .arm64 : .amd64,
        MaxVcpus: int(w[int(ProbeWord.maxVcpus)]),
        InKernelIrqChip: w[int(ProbeWord.inKernelIrqChip)] != 0,
        Doorbells: w[int(ProbeWord.doorbells)] != 0,
        HyperV: w[int(ProbeWord.hyperV)] != 0,
        DirtyLogging: w[int(ProbeWord.dirtyLogging)] != 0,
        PartitionsPerProcess: int(w[int(ProbeWord.partitionsPerProcess)]),
        PhysicalAddressBits: int(w[int(ProbeWord.physicalAddressBits)])
    )
}

/// Makes a partition for up to `vcpus` vCPUs. On macOS a process can hold
/// only one; a second throws `busy`.
public func Create(vcpus: int) throws -> Partition {
    let h = hvCreate(int32(vcpus))
    if h < 0 {
        throw errorFor(h, "creating a partition")
    }
    return Partition(handle: h)
}

/// Guest-physical memory, an interrupt controller and vCPUs.
///
///     let p = try hypervisor.Create(vcpus: 2)
///     defer { p.Close() }
public final class Partition {
    let handle: int64
    var closed = false

    init(handle: int64) {
        self.handle = handle
    }

    /// Creates the in-kernel interrupt controller. On arm64 it is a GICv3
    /// at the given addresses, with an MSI frame if `msiBase` isn't 0. On
    /// amd64 the addresses are ignored.
    public func CreateIrqChip(distributor: uint64 = 0, redistributor: uint64 = 0,
                              msiBase: uint64 = 0, msiFirst: uint32 = 0, msiCount: uint32 = 0) throws {
        try check(hvCreateIrqChip(handle, distributor, redistributor, msiBase, msiFirst, msiCount),
                  "creating the interrupt controller")
    }

    /// Maps `count` bytes of host memory into the guest at `guest`. The
    /// memory must stay mapped in this process until `Unmap` or `Close`.
    public func Map(guest: uint64, host: UnsafeMutableRawPointer, count: uint64,
                    access: Access = .all) throws {
        try check(hvMap(handle, guest, host, count, access.bits),
                  "mapping \(count) bytes at guest 0x\(string(guest, radix: 16))")
    }

    public func Unmap(guest: uint64, count: uint64) throws {
        try check(hvUnmap(handle, guest, count), "unmapping guest 0x\(string(guest, radix: 16))")
    }

    /// Drives a line of the in-kernel controller: a GIC SPI number, or an
    /// IOAPIC pin. Throws `unsupported` where there's no in-kernel IOAPIC
    /// (WHP); use `SendMsi` from an IOAPIC model there.
    public func SetIrq(_ line: uint32, level: bool) throws {
        try check(hvSetIrq(handle, line, level), "setting interrupt line \(line)")
    }

    public func SendMsi(address: uint64, data: uint32) throws {
        try check(hvSendMsi(handle, address, data), "sending an MSI")
    }

    /// Creates vCPU `id`. HVF binds a vCPU to the thread that makes it, so
    /// call this on the thread that will call `Run`.
    public func CreateVcpu(_ id: int) throws -> Vcpu {
        let v = hvCreateVcpu(handle, int32(id))
        if v < 0 {
            throw errorFor(v, "creating vCPU \(id)")
        }
        return Vcpu(handle: v, id: id)
    }

    public func Close() {
        if closed { return }
        closed = true
        hvClose(handle)
    }

    deinit {
        Close()
    }
}

/// One virtual CPU. `Run` blocks the calling thread, which must be the
/// vCPU's own thread; every other method may be called from anywhere.
public final class Vcpu {
    let handle: int64
    public let Id: int
    var exitWords = [uint64](repeating: 0, count: 8)
    var closed = false

    init(handle: int64, id: int) {
        self.handle = handle
        Id = id
    }

    /// Runs the guest until it exits, and says why.
    public func Run() throws -> Exit {
        let kind = exitWords.withUnsafeMutableBufferPointer { hvRun(handle, $0.baseAddress) }
        if kind < 0 {
            throw errorFor(int64(kind), "running vCPU \(Id)")
        }
        return decodeExit(kind, exitWords)
    }

    /// Finishes the last exit: the value of an MMIO, port or register read
    /// (ignored for writes), and the pc moved past the instruction.
    public func Complete(read value: uint64 = 0) throws {
        try check(hvComplete(handle, value), "completing an exit on vCPU \(Id)")
    }

    /// Reads one register by the platform-neutral number in `RegArm64` /
    /// `RegAmd64`. Most callers use `Registers` instead.
    public func Get(_ reg: int32) throws -> uint64 {
        var value: uint64 = 0
        try check(hvGetReg(handle, reg, &value), "reading register \(reg)")
        return value
    }

    public func Set(_ reg: int32, _ value: uint64) throws {
        try check(hvSetReg(handle, reg, value), "writing register \(reg)")
    }

    /// Unmasks the virtual timer after its interrupt went in (HVF).
    public func UnmaskTimer() throws {
        try check(hvUnmaskTimer(handle), "unmasking the timer")
    }

    /// Makes `Run` return `.canceled` soon. Safe from any thread.
    public func Kick() {
        _ = hvKick(handle)
    }

    public func Close() {
        if closed { return }
        closed = true
        hvCloseVcpu(handle)
    }

    deinit {
        Close()
    }
}
