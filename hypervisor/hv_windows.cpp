// Windows Hypervisor Platform, for package vm/hypervisor: see hv.cpp.
//
// amd64. WHP emulates the LAPIC. The IOAPIC and PIC are the VMM's, so
// probe reports inKernelIrqChip = 0 and vm puts chipset.IoApic on the bus.
//
// An MMIO or port exit only gives the instruction bytes. Decoding them is
// WinHvEmulation.dll's job, another part of the OS. Its callbacks want a
// read's value at once, but our value comes from Vertex after hvRun has
// returned. So each access is emulated twice:
//   1. In hvRun, a pass that records the access and changes no registers.
//   2. In hvComplete, a pass that answers with the value and commits.
module;
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <WinHvPlatform.h>
#include <WinHvEmulation.h>
#pragma comment(lib, "WinHvPlatform")
#pragma comment(lib, "WinHvEmulation")
module vm.hypervisor;

namespace {

constexpr int maxPartitions = 8;
constexpr int maxVcpus = 64;

struct Access {
    int32_t kind = 0;         // ExitKind::mmio / io, 0 for none
    uint64_t address = 0;
    uint32_t size = 0;
    bool write = false;
    uint64_t value = 0;
    bool commit = false;      // the second pass
};

struct Vcpu {
    bool used = false;
    int partition = -1;
    UINT32 index = 0;
    WHV_EMULATOR_HANDLE emulator = nullptr;
    WHV_RUN_VP_EXIT_CONTEXT exit{};
    Access access;
};

WHV_PARTITION_HANDLE partitions[maxPartitions] = {};
Vcpu vcpus[maxVcpus];
thread_local int32_t lastErr = 0;

int32_t fail(HRESULT hr) {
    if (SUCCEEDED(hr)) return Code::ok;
    lastErr = (int32_t)hr;
    if (hr == E_ACCESSDENIED) return Code::denied;
    if (hr == E_OUTOFMEMORY) return Code::noMemory;
    if (hr == E_INVALIDARG) return Code::invalid;
    if (hr == WHV_E_UNKNOWN_CAPABILITY || hr == E_NOTIMPL) return Code::unsupported;
    return Code::generic;
}

Vcpu* vcpu(int64_t v) {
    if (v < 0 || v >= maxVcpus || !vcpus[v].used) return nullptr;
    return &vcpus[v];
}

WHV_PARTITION_HANDLE part(int64_t p) {
    if (p < 0 || p >= maxPartitions) return nullptr;
    return partitions[p];
}

// ---- Emulator callbacks ----------------------------------------------------

HRESULT CALLBACK onIo(VOID* ctx, WHV_EMULATOR_IO_ACCESS_INFO* io) {
    Access& a = ((Vcpu*)ctx)->access;
    a.kind = ExitKind::io;
    a.address = io->Port;
    a.size = io->AccessSize;
    a.write = io->Direction == 1;
    if (a.write) a.value = io->Data;
    else if (a.commit) io->Data = (UINT32)a.value;
    return S_OK;
}

HRESULT CALLBACK onMemory(VOID* ctx, WHV_EMULATOR_MEMORY_ACCESS_INFO* m) {
    Access& a = ((Vcpu*)ctx)->access;
    a.kind = ExitKind::mmio;
    a.address = m->GpaAddress;
    a.size = m->AccessSize;
    a.write = m->Direction == 1;
    if (a.write) {
        uint64_t v = 0;
        memcpy(&v, m->Data, a.size <= 8 ? a.size : 8);
        a.value = v;
    } else if (a.commit) {
        memcpy(m->Data, &a.value, a.size <= 8 ? a.size : 8);
    }
    return S_OK;
}

HRESULT CALLBACK onGetRegs(VOID* ctx, const WHV_REGISTER_NAME* names, UINT32 count, WHV_REGISTER_VALUE* values) {
    Vcpu* v = (Vcpu*)ctx;
    return WHvGetVirtualProcessorRegisters(partitions[v->partition], v->index, names, count, values);
}

HRESULT CALLBACK onSetRegs(VOID* ctx, const WHV_REGISTER_NAME* names, UINT32 count, const WHV_REGISTER_VALUE* values) {
    Vcpu* v = (Vcpu*)ctx;
    if (!v->access.commit) return S_OK;   // the discovery pass changes nothing
    return WHvSetVirtualProcessorRegisters(partitions[v->partition], v->index, names, count, values);
}

HRESULT CALLBACK onTranslate(VOID* ctx, WHV_GUEST_VIRTUAL_ADDRESS gva, WHV_TRANSLATE_GVA_FLAGS flags,
                             WHV_TRANSLATE_GVA_RESULT_CODE* result, WHV_GUEST_PHYSICAL_ADDRESS* gpa) {
    Vcpu* v = (Vcpu*)ctx;
    WHV_TRANSLATE_GVA_RESULT r{};
    HRESULT hr = WHvTranslateGva(partitions[v->partition], v->index, gva, flags, &r, gpa);
    *result = r.ResultCode;
    return hr;
}

const WHV_EMULATOR_CALLBACKS callbacks = {
    sizeof(WHV_EMULATOR_CALLBACKS), 0, onIo, onMemory, onGetRegs, onSetRegs, onTranslate,
};

HRESULT emulate(Vcpu* v) {
    WHV_EMULATOR_STATUS status{};
    if (v->exit.ExitReason == WHvRunVpExitReasonMemoryAccess) {
        return WHvEmulatorTryMmioEmulation(v->emulator, v, &v->exit.VpContext, &v->exit.MemoryAccess, &status);
    }
    return WHvEmulatorTryIoEmulation(v->emulator, v, &v->exit.VpContext, &v->exit.IoPortAccess, &status);
}

WHV_REGISTER_NAME regName(int32_t reg, bool* ok) {
    static const WHV_REGISTER_NAME names[] = {
        WHvX64RegisterRax, WHvX64RegisterRcx, WHvX64RegisterRdx, WHvX64RegisterRbx,
        WHvX64RegisterRsp, WHvX64RegisterRbp, WHvX64RegisterRsi, WHvX64RegisterRdi,
        WHvX64RegisterR8, WHvX64RegisterR9, WHvX64RegisterR10, WHvX64RegisterR11,
        WHvX64RegisterR12, WHvX64RegisterR13, WHvX64RegisterR14, WHvX64RegisterR15,
        WHvX64RegisterRip, WHvX64RegisterRflags,
        WHvX64RegisterCr0, WHvX64RegisterCr3, WHvX64RegisterCr4, WHvX64RegisterEfer,
    };
    *ok = reg >= 0 && reg <= RegAmd64::efer;
    return *ok ? names[reg] : WHvX64RegisterRax;
}

} // namespace

int32_t hvProbe(uint64_t* out, int32_t count) noexcept {
    if (!out || count < ProbeWord::count) return Code::invalid;
    WHV_CAPABILITY cap{};
    UINT32 size = 0;
    HRESULT hr = WHvGetCapability(WHvCapabilityCodeHypervisorPresent, &cap, sizeof cap, &size);
    if (FAILED(hr)) return fail(hr);
    if (!cap.HypervisorPresent) return Code::denied;   // the optional feature is off
    out[ProbeWord::arch] = ArchCode::amd64;
    out[ProbeWord::maxVcpus] = maxVcpus;
    out[ProbeWord::inKernelIrqChip] = 0;               // LAPIC only
    out[ProbeWord::doorbells] = 1;                     // WHvRegisterPartitionDoorbellEvent
    out[ProbeWord::hyperV] = 1;                        // synthetic processor features
    out[ProbeWord::dirtyLogging] = 1;
    out[ProbeWord::partitionsPerProcess] = maxPartitions;
    out[ProbeWord::physicalAddressBits] = 46;          // TODO: CPUID 0x80000008
    return Code::ok;
}

int64_t hvCreate(int32_t vcpuCount) noexcept {
    for (int i = 0; i < maxPartitions; i++) {
        if (partitions[i]) continue;
        WHV_PARTITION_HANDLE h = nullptr;
        HRESULT hr = WHvCreatePartition(&h);
        if (FAILED(hr)) return fail(hr);
        WHV_PARTITION_PROPERTY prop{};
        prop.ProcessorCount = (UINT32)vcpuCount;
        hr = WHvSetPartitionProperty(h, WHvPartitionPropertyCodeProcessorCount, &prop, sizeof prop);
        if (SUCCEEDED(hr)) {
            // Exit on CPUID so vm can add its own leaves (Hyper-V, topology).
            WHV_EXTENDED_VM_EXITS exits{};
            exits.X64CpuidExit = 1;
            exits.X64MsrExit = 1;
            memset(&prop, 0, sizeof prop);
            prop.ExtendedVmExits = exits;
            hr = WHvSetPartitionProperty(h, WHvPartitionPropertyCodeExtendedVmExits, &prop, sizeof prop);
        }
        if (FAILED(hr)) { WHvDeletePartition(h); return fail(hr); }
        partitions[i] = h;
        return i;
    }
    return Code::noMemory;
}

int32_t hvCreateIrqChip(int64_t p, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t) noexcept {
    WHV_PARTITION_HANDLE h = part(p);
    if (!h) return Code::invalid;
    WHV_PARTITION_PROPERTY prop{};
    prop.LocalApicEmulationMode = WHvX64LocalApicEmulationModeXApic;
    HRESULT hr = WHvSetPartitionProperty(h, WHvPartitionPropertyCodeLocalApicEmulationMode, &prop, sizeof prop);
    if (FAILED(hr)) return fail(hr);
    // The partition's properties are set; now it can be made real.
    return fail(WHvSetupPartition(h));
}

int32_t hvMap(int64_t p, uint64_t gpa, void* host, uint64_t count, int32_t access) noexcept {
    WHV_PARTITION_HANDLE h = part(p);
    if (!h || !host) return Code::invalid;
    WHV_MAP_GPA_RANGE_FLAGS flags = WHvMapGpaRangeFlagNone;
    if (access & AccessBit::read) flags |= WHvMapGpaRangeFlagRead;
    if (access & AccessBit::write) flags |= WHvMapGpaRangeFlagWrite;
    if (access & AccessBit::execute) flags |= WHvMapGpaRangeFlagExecute;
    return fail(WHvMapGpaRange(h, host, gpa, count, flags));
}

int32_t hvUnmap(int64_t p, uint64_t gpa, uint64_t count) noexcept {
    WHV_PARTITION_HANDLE h = part(p);
    if (!h) return Code::invalid;
    return fail(WHvUnmapGpaRange(h, gpa, count));
}

int32_t hvSetIrq(int64_t p, uint32_t line, bool level) noexcept {
    // There's no IOAPIC here. chipset.IoApic turns lines into LAPIC
    // interrupts and delivers them through hvSendMsi.
    (void)p; (void)line; (void)level;
    return Code::unsupported;
}

int32_t hvSendMsi(int64_t p, uint64_t address, uint32_t data) noexcept {
    WHV_PARTITION_HANDLE h = part(p);
    if (!h) return Code::invalid;
    WHV_INTERRUPT_CONTROL ic{};
    ic.Type = WHvX64InterruptTypeFixed;
    ic.DestinationMode = (address >> 2) & 1 ? WHvX64InterruptDestinationModeLogical
                                            : WHvX64InterruptDestinationModePhysical;
    ic.TriggerMode = (data >> 15) & 1 ? WHvX64InterruptTriggerModeLevel : WHvX64InterruptTriggerModeEdge;
    ic.Destination = (UINT32)((address >> 12) & 0xff);
    ic.Vector = data & 0xff;
    return fail(WHvRequestInterrupt(h, &ic, sizeof ic));
}

void hvClose(int64_t p) noexcept {
    WHV_PARTITION_HANDLE h = part(p);
    if (!h) return;
    for (auto& v : vcpus) {
        if (v.used && v.partition == p) {
            WHvEmulatorDestroyEmulator(v.emulator);
            WHvDeleteVirtualProcessor(h, v.index);
            v = Vcpu{};
        }
    }
    WHvDeletePartition(h);
    partitions[p] = nullptr;
}

int64_t hvCreateVcpu(int64_t p, int32_t id) noexcept {
    WHV_PARTITION_HANDLE h = part(p);
    if (!h || id < 0) return Code::invalid;
    for (int i = 0; i < maxVcpus; i++) {
        if (vcpus[i].used) continue;
        HRESULT hr = WHvCreateVirtualProcessor(h, (UINT32)id, 0);
        if (FAILED(hr)) return fail(hr);
        WHV_EMULATOR_HANDLE e = nullptr;
        hr = WHvEmulatorCreateEmulator(&callbacks, &e);
        if (FAILED(hr)) { WHvDeleteVirtualProcessor(h, (UINT32)id); return fail(hr); }
        vcpus[i] = Vcpu{};
        vcpus[i].used = true;
        vcpus[i].partition = (int)p;
        vcpus[i].index = (UINT32)id;
        vcpus[i].emulator = e;
        return i;
    }
    return Code::noMemory;
}

int32_t hvRun(int64_t handle, uint64_t* out) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v || !out) return Code::invalid;
    for (int i = 0; i < ExitKind::words; i++) out[i] = 0;
    v->access = Access{};

    HRESULT hr = WHvRunVirtualProcessor(partitions[v->partition], v->index, &v->exit, sizeof v->exit);
    if (FAILED(hr)) return fail(hr);

    switch (v->exit.ExitReason) {
    case WHvRunVpExitReasonMemoryAccess:
    case WHvRunVpExitReasonX64IoPortAccess: {
        hr = emulate(v);   // discovery pass
        if (FAILED(hr) || v->access.kind == 0) { out[0] = (uint64_t)hr; return ExitKind::failed; }
        out[0] = v->access.address;
        out[1] = v->access.size;
        out[2] = v->access.write;
        out[3] = v->access.write ? v->access.value : 0;
        return v->access.kind;
    }
    case WHvRunVpExitReasonX64Cpuid:
        out[0] = v->exit.CpuidAccess.Rax;
        out[1] = v->exit.CpuidAccess.Rcx;
        return ExitKind::cpuid;
    case WHvRunVpExitReasonX64MsrAccess:
        out[0] = v->exit.MsrAccess.MsrNumber;
        out[2] = v->exit.MsrAccess.AccessInfo.IsWrite;
        out[3] = (v->exit.MsrAccess.Rdx << 32) | (v->exit.MsrAccess.Rax & 0xffffffff);
        return ExitKind::sysreg;
    case WHvRunVpExitReasonX64Halt:
        return ExitKind::halt;
    case WHvRunVpExitReasonCanceled:
        return ExitKind::canceled;
    case WHvRunVpExitReasonUnrecoverableException:
        return ExitKind::shutdown;
    default:
        out[0] = v->exit.ExitReason;
        return ExitKind::failed;
    }
}

int32_t hvComplete(int64_t handle, uint64_t value) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
    WHV_PARTITION_HANDLE h = partitions[v->partition];
    switch (v->exit.ExitReason) {
    case WHvRunVpExitReasonMemoryAccess:
    case WHvRunVpExitReasonX64IoPortAccess:
        v->access.commit = true;
        v->access.value = v->access.write ? v->access.value : value;
        return fail(emulate(v));   // commit pass: registers and rip updated
    case WHvRunVpExitReasonX64Cpuid: {
        // vm has already set rax, rbx, rcx and rdx with hvSetReg; only rip moves here.
        WHV_REGISTER_NAME name = WHvX64RegisterRip;
        WHV_REGISTER_VALUE rip{};
        rip.Reg64 = v->exit.VpContext.Rip + v->exit.VpContext.InstructionLength;
        return fail(WHvSetVirtualProcessorRegisters(h, v->index, &name, 1, &rip));
    }
    case WHvRunVpExitReasonX64MsrAccess: {
        WHV_REGISTER_NAME names[3] = { WHvX64RegisterRax, WHvX64RegisterRdx, WHvX64RegisterRip };
        WHV_REGISTER_VALUE vals[3] = {};
        UINT32 n = 1;
        names[0] = WHvX64RegisterRip;
        vals[0].Reg64 = v->exit.VpContext.Rip + v->exit.VpContext.InstructionLength;
        if (!v->exit.MsrAccess.AccessInfo.IsWrite) {
            names[1] = WHvX64RegisterRax; vals[1].Reg64 = value & 0xffffffff;
            names[2] = WHvX64RegisterRdx; vals[2].Reg64 = value >> 32;
            n = 3;
        }
        return fail(WHvSetVirtualProcessorRegisters(h, v->index, names, n, vals));
    }
    default:
        return Code::ok;
    }
}

int32_t hvGetReg(int64_t handle, int32_t reg, uint64_t* out) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v || !out) return Code::invalid;
    bool ok;
    WHV_REGISTER_NAME name = regName(reg, &ok);
    if (!ok) return Code::invalid;
    WHV_REGISTER_VALUE value{};
    HRESULT hr = WHvGetVirtualProcessorRegisters(partitions[v->partition], v->index, &name, 1, &value);
    if (FAILED(hr)) return fail(hr);
    *out = value.Reg64;
    return Code::ok;
}

int32_t hvSetReg(int64_t handle, int32_t reg, uint64_t v64) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
    bool ok;
    WHV_REGISTER_NAME name = regName(reg, &ok);
    if (!ok) return Code::invalid;
    WHV_REGISTER_VALUE value{};
    value.Reg64 = v64;
    return fail(WHvSetVirtualProcessorRegisters(partitions[v->partition], v->index, &name, 1, &value));
}

int32_t hvSetSegment(int64_t handle, int32_t seg, uint64_t base, uint32_t limit,
                     uint16_t selector, uint16_t attributes) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
    static const WHV_REGISTER_NAME names[] = {
        WHvX64RegisterCs, WHvX64RegisterDs, WHvX64RegisterEs, WHvX64RegisterFs, WHvX64RegisterGs,
        WHvX64RegisterSs, WHvX64RegisterTr, WHvX64RegisterLdtr, WHvX64RegisterGdtr, WHvX64RegisterIdtr,
    };
    if (seg < 0 || seg > SegAmd64::idtr) return Code::invalid;
    WHV_REGISTER_VALUE value{};
    if (seg == SegAmd64::gdtr || seg == SegAmd64::idtr) {
        value.Table.Base = base;
        value.Table.Limit = (UINT16)limit;
    } else {
        value.Segment.Base = base;
        value.Segment.Limit = limit;
        value.Segment.Selector = selector;
        value.Segment.Attributes = attributes;
    }
    return fail(WHvSetVirtualProcessorRegisters(partitions[v->partition], v->index, &names[seg], 1, &value));
}

int32_t hvUnmaskTimer(int64_t) noexcept { return Code::ok; }

int32_t hvKick(int64_t handle) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
    return fail(WHvCancelRunVirtualProcessor(partitions[v->partition], v->index, 0));
}

void hvCloseVcpu(int64_t handle) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return;
    WHvEmulatorDestroyEmulator(v->emulator);
    WHvDeleteVirtualProcessor(partitions[v->partition], v->index);
    *v = Vcpu{};
}

int32_t lastError() noexcept { return lastErr; }
