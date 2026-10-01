// The operating system's hypervisor, for package vm/hypervisor. It is the
// only native code in the vm repository.
//
// A partition is guest physical memory plus vCPUs; nothing here knows what
// a device is. Each platform unit implements every export below:
//
//   hv_darwin.cpp    Hypervisor.framework (arm64; macOS 15 for hv_gic)
//   hv_windows.cpp   Windows Hypervisor Platform (amd64)
//   hv_linux.cpp     /dev/kvm (arm64 and amd64)
//   hv_android.cpp   unsupported: apps can't open /dev/kvm
//
// hvRun is the one export that blocks. It runs on a vCPU's own thread,
// never on a task executor's, and hvKick is how another thread gets it
// back. Everything else returns at once.
module;
#include <stdint.h>
#include <stddef.h>
export module vm.hypervisor;

// Results: 0 or a handle/count on success, one of these on failure.
export namespace Code {
    constexpr int32_t ok = 0;
    constexpr int32_t generic = -1;
    constexpr int32_t unsupported = -2;   // no hypervisor, or not on this platform
    constexpr int32_t denied = -3;        // missing entitlement, feature or /dev/kvm access
    constexpr int32_t noMemory = -4;
    constexpr int32_t invalid = -5;       // bad argument, handle or register
    constexpr int32_t busy = -6;          // HVF: this process already has a VM
    constexpr int32_t exists = -7;
}

// The architecture guests run as: always the host's.
export namespace ArchCode {
    constexpr int32_t arm64 = 1;
    constexpr int32_t amd64 = 2;
}

// What hvProbe writes, one uint64 word per field.
export namespace ProbeWord {
    constexpr int32_t arch = 0;
    constexpr int32_t maxVcpus = 1;
    constexpr int32_t inKernelIrqChip = 2;
    constexpr int32_t doorbells = 3;
    constexpr int32_t hyperV = 4;
    constexpr int32_t dirtyLogging = 5;
    constexpr int32_t partitionsPerProcess = 6;
    constexpr int32_t physicalAddressBits = 7;
    constexpr int32_t count = 8;
}

// Memory access a mapping allows, as bits.
export namespace AccessBit {
    constexpr int32_t read = 1;
    constexpr int32_t write = 2;
    constexpr int32_t execute = 4;
}

// Why hvRun returned. The words of the exit buffer each kind fills are
// listed with it; unused words are 0.
export namespace ExitKind {
    constexpr int32_t mmio = 1;         // [0] address [1] size [2] write [3] value (for writes)
    constexpr int32_t io = 2;           // [0] port [1] size [2] write [3] value (for writes)  amd64
    constexpr int32_t hypercall = 3;    // [0] kind (CallKind) [1] immediate [4..7] x0..x3 / rcx,rdx,r8,r9
    constexpr int32_t sysreg = 4;       // [0] id [2] write [3] value (for writes)  arm64 sysreg, amd64 MSR
    constexpr int32_t cpuid = 5;        // [0] leaf [1] subleaf
    constexpr int32_t halt = 6;         // WFI / HLT with nothing pending
    constexpr int32_t shutdown = 7;     // triple fault, KVM system event, PSCI handled in kernel
    constexpr int32_t canceled = 8;     // hvKick
    constexpr int32_t vtimer = 9;       // HVF: the virtual timer fired and is now masked
    constexpr int32_t failed = 10;      // [0] the platform's own reason code
    constexpr int32_t words = 8;        // the size of the exit buffer
}

export namespace CallKind {
    constexpr int32_t hvc = 1;
    constexpr int32_t smc = 2;
    constexpr int32_t vmcall = 3;
}

// Register numbers for hvGetReg / hvSetReg. Numbers of the other arch are
// `invalid`.
namespace RegArm64 {
    constexpr int32_t x0 = 0;           // x0..x30 are 0..30
    constexpr int32_t sp = 31;          // SP_EL1
    constexpr int32_t pc = 32;
    constexpr int32_t pstate = 33;
    constexpr int32_t mpidr = 34;       // MPIDR_EL1 (read; set where the platform allows)
    constexpr int32_t elr_el1 = 35;
    constexpr int32_t esr_el1 = 36;
    constexpr int32_t far_el1 = 37;
    constexpr int32_t vbar_el1 = 38;
    // Any other system register: sysreg | op0<<14 | op1<<11 | CRn<<7 | CRm<<3 | op2,
    // the MRS encoding (HVF's hv_sys_reg_t, KVM's ARM64_SYS_REG).
    constexpr int32_t sysreg = 0x10000;
}
namespace RegAmd64 {
    constexpr int32_t rax = 0, rcx = 1, rdx = 2, rbx = 3, rsp = 4, rbp = 5, rsi = 6, rdi = 7;
    constexpr int32_t r8 = 8;           // r8..r15 are 8..15
    constexpr int32_t rip = 16;
    constexpr int32_t rflags = 17;
    constexpr int32_t cr0 = 18, cr3 = 19, cr4 = 20, efer = 21;
}
namespace SegAmd64 {
    constexpr int32_t cs = 0, ds = 1, es = 2, fs = 3, gs = 4, ss = 5, tr = 6, ldtr = 7;
    constexpr int32_t gdtr = 8, idtr = 9;    // base and limit only
}

// ---- The partition ------------------------------------------------------

// Capabilities, one word per ProbeWord, into out.
export int32_t hvProbe(uint64_t* out, int32_t count) noexcept;

// A partition sized for vcpus: its handle (>= 0), or a code.
export int64_t hvCreate(int32_t vcpus) noexcept;

// The in-kernel interrupt controller. arm64: a GICv3 at the given bases
// (msiBase 0 for none). amd64: LAPIC (and IOAPIC where the platform has
// one); the addresses are ignored.
export int32_t hvCreateIrqChip(int64_t p, uint64_t distributor, uint64_t redistributor,
                               uint64_t msiBase, uint32_t msiFirst, uint32_t msiCount) noexcept;

// Maps count bytes of host memory at host into the guest at gpa.
export int32_t hvMap(int64_t p, uint64_t gpa, void* host, uint64_t count, int32_t access) noexcept;
export int32_t hvUnmap(int64_t p, uint64_t gpa, uint64_t count) noexcept;

// Drives an interrupt line of the in-kernel controller (a GIC SPI, an
// IOAPIC pin), or signals a message-signalled interrupt.
export int32_t hvSetIrq(int64_t p, uint32_t line, bool level) noexcept;
export int32_t hvSendMsi(int64_t p, uint64_t address, uint32_t data) noexcept;

export void hvClose(int64_t p) noexcept;

// ---- vCPUs -----------------------------------------------------------------

// A vCPU: its handle, or a code. HVF binds a vCPU to the thread that
// creates it, so create it on the thread that will run it.
export int64_t hvCreateVcpu(int64_t p, int32_t id) noexcept;

// Runs the guest until it exits: the ExitKind, with the details in exit
// (ExitKind::words words), or a negative code.
export int32_t hvRun(int64_t v, uint64_t* exit) noexcept;

// Finishes the exit hvRun last returned: the value an mmio, io or sysreg
// read produced (ignored for writes), and the guest's pc moved past the
// instruction where the platform leaves that to us. For cpuid, set the four
// result registers with hvSetReg first; the value is ignored.
export int32_t hvComplete(int64_t v, uint64_t value) noexcept;

export int32_t hvGetReg(int64_t v, int32_t reg, uint64_t* out) noexcept;
export int32_t hvSetReg(int64_t v, int32_t reg, uint64_t value) noexcept;

// amd64 segments and descriptor tables; unsupported on arm64.
export int32_t hvSetSegment(int64_t v, int32_t seg, uint64_t base, uint32_t limit,
                            uint16_t selector, uint16_t attributes) noexcept;

// HVF: unmask the virtual timer after its interrupt has been delivered.
// Elsewhere a no-op.
export int32_t hvUnmaskTimer(int64_t v) noexcept;

// Reads an in-kernel interrupt controller register, for diagnostics:
// kind 0 the distributor (v ignored), 1 vCPU v's redistributor, 2 its CPU
// interface (ICC). reg is the platform's own number for it. Call it on the
// vCPU's thread.
export int32_t hvGicReg(int64_t v, int32_t kind, uint32_t reg, uint64_t* out) noexcept;

// From any thread: makes the vCPU's hvRun return ExitKind::canceled soon.
export int32_t hvKick(int64_t v) noexcept;

export void hvCloseVcpu(int64_t v) noexcept;

// The OS's own error number for the last failure on this thread.
export int32_t lastError() noexcept;
