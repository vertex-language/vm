// Hypervisor.framework, for package vm/hypervisor: see hv.cpp.
//
// Apple Silicon only. A process has at most one VM, so the partition handle
// is always 0. The in-kernel GICv3 (hv_gic_*) needs macOS 15, which is why
// vs.mod says so. The binary must be signed with the
// com.apple.security.hypervisor entitlement, or hv_vm_create is denied.
module;
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <Hypervisor/Hypervisor.h>
#pragma vertex framework("Hypervisor")
// TODO(vsc): #pragma vertex entitlement("com.apple.security.hypervisor")
module vm.hypervisor;

#if defined(__aarch64__)

namespace {

constexpr int maxVcpus = 64;

// What the last exit left for hvComplete to finish.
struct Pending {
    bool mmioRead = false;
    uint32_t reg = 31;          // the SRT of a data abort: where a read lands
    bool advance = false;       // move pc past a trapped instruction
};

struct Vcpu {
    bool used = false;
    hv_vcpu_t id = 0;
    hv_vcpu_exit_t* exit = nullptr;
    Pending pending;
};

bool vmCreated = false;
Vcpu vcpus[maxVcpus];
thread_local int32_t lastErr = 0;

int32_t fail(hv_return_t r) {
    lastErr = (int32_t)r;
    switch (r) {
    case HV_SUCCESS: return Code::ok;
    case HV_NO_RESOURCES: return Code::noMemory;
    case HV_NO_DEVICE: return Code::unsupported;
    case HV_DENIED: return Code::denied;
    case HV_BAD_ARGUMENT: return Code::invalid;
    case HV_BUSY: return Code::busy;
    case HV_UNSUPPORTED: return Code::unsupported;
    default: return Code::generic;
    }
}

Vcpu* lookup(int64_t v) {
    if (v < 0 || v >= maxVcpus || !vcpus[v].used) return nullptr;
    return &vcpus[v];
}

bool gpr(int32_t reg, hv_reg_t* out) {
    if (reg >= RegArm64::x0 && reg <= 30) { *out = (hv_reg_t)(HV_REG_X0 + reg); return true; }
    if (reg == RegArm64::pc) { *out = HV_REG_PC; return true; }
    if (reg == RegArm64::pstate) { *out = HV_REG_CPSR; return true; }
    return false;
}

} // namespace

int32_t hvProbe(uint64_t* out, int32_t count) noexcept {
    if (!out || count < ProbeWord::count) return Code::invalid;
    uint32_t max = 0;
    hv_return_t r = hv_vm_get_max_vcpu_count(&max);
    if (r != HV_SUCCESS) return fail(r);
    uint32_t ipa = 0;
    hv_vm_config_get_max_ipa_size(&ipa);
    out[ProbeWord::arch] = ArchCode::arm64;
    out[ProbeWord::maxVcpus] = max < maxVcpus ? max : maxVcpus;
    out[ProbeWord::inKernelIrqChip] = 1;
    out[ProbeWord::doorbells] = 0;
    out[ProbeWord::hyperV] = 0;
    out[ProbeWord::dirtyLogging] = 0;
    out[ProbeWord::partitionsPerProcess] = 1;
    out[ProbeWord::physicalAddressBits] = ipa;
    return Code::ok;
}

int64_t hvCreate(int32_t vcpuCount) noexcept {
    (void)vcpuCount;
    if (vmCreated) return Code::busy;
    hv_vm_config_t config = hv_vm_config_create();
    uint32_t ipa = 0;
    if (hv_vm_config_get_max_ipa_size(&ipa) == HV_SUCCESS) hv_vm_config_set_ipa_size(config, ipa);
    hv_return_t r = hv_vm_create(config);
    os_release(config);
    if (r != HV_SUCCESS) return fail(r);
    vmCreated = true;
    return 0;
}

int32_t hvCreateIrqChip(int64_t p, uint64_t distributor, uint64_t redistributor,
                        uint64_t msiBase, uint32_t msiFirst, uint32_t msiCount) noexcept {
    if (p != 0 || !vmCreated) return Code::invalid;
    hv_gic_config_t config = hv_gic_config_create();
    hv_return_t r = hv_gic_config_set_distributor_base(config, distributor);
    if (r == HV_SUCCESS) r = hv_gic_config_set_redistributor_base(config, redistributor);
    if (r == HV_SUCCESS && msiBase != 0) {
        r = hv_gic_config_set_msi_region_base(config, msiBase);
        if (r == HV_SUCCESS) r = hv_gic_config_set_msi_interrupt_range(config, msiFirst, msiCount);
    }
    if (r == HV_SUCCESS) r = hv_gic_create(config);
    os_release(config);
    return fail(r);
}

int32_t hvMap(int64_t p, uint64_t gpa, void* host, uint64_t count, int32_t access) noexcept {
    if (p != 0 || !host) return Code::invalid;
    hv_memory_flags_t flags = 0;
    if (access & AccessBit::read) flags |= HV_MEMORY_READ;
    if (access & AccessBit::write) flags |= HV_MEMORY_WRITE;
    if (access & AccessBit::execute) flags |= HV_MEMORY_EXEC;
    return fail(hv_vm_map(host, gpa, count, flags));
}

int32_t hvUnmap(int64_t p, uint64_t gpa, uint64_t count) noexcept {
    if (p != 0) return Code::invalid;
    return fail(hv_vm_unmap(gpa, count));
}

int32_t hvSetIrq(int64_t p, uint32_t line, bool level) noexcept {
    if (p != 0) return Code::invalid;
    uint32_t intid = (line < 32) ? (32 + line) : line;
    return fail(hv_gic_set_spi(intid, level));
}

int32_t hvSendMsi(int64_t p, uint64_t address, uint32_t data) noexcept {
    if (p != 0) return Code::invalid;
    return fail(hv_gic_send_msi(address, data));
}

void hvClose(int64_t p) noexcept {
    if (p != 0 || !vmCreated) return;
    for (auto& v : vcpus) {
        if (v.used) { hv_vcpu_destroy(v.id); v = Vcpu{}; }
    }
    hv_vm_destroy();
    vmCreated = false;
}

int64_t hvCreateVcpu(int64_t p, int32_t id) noexcept {
    if (p != 0 || id < 0 || id >= maxVcpus || vcpus[id].used) return Code::invalid;
    Vcpu& v = vcpus[id];
    hv_return_t r = hv_vcpu_create(&v.id, &v.exit, nullptr);
    if (r != HV_SUCCESS) return fail(r);
    // Affinity 0 carries the vCPU number, the way the FDT/MADT name CPUs.
    hv_vcpu_set_sys_reg(v.id, HV_SYS_REG_MPIDR_EL1, (uint64_t)id & 0xff);
    // With the in-kernel GIC, HVF stops trapping PMU registers to us and
    // injects UNDEF unless ID_AA64DFR0_EL1.PMUVer advertises a PMU; then it
    // emulates PMUv3 itself. Windows' bootmgr reads PMCR_EL0 unconditionally.
    uint64_t dfr0 = 0;
    if (hv_vcpu_get_sys_reg(v.id, HV_SYS_REG_ID_AA64DFR0_EL1, &dfr0) == HV_SUCCESS &&
        ((dfr0 >> 8) & 0xf) == 0) {
        hv_vcpu_set_sys_reg(v.id, HV_SYS_REG_ID_AA64DFR0_EL1, (dfr0 & ~0xf00ull) | 0x100);
    }
    v.used = true;
    return id;
}

int32_t hvRun(int64_t handle, uint64_t* out) noexcept {
    Vcpu* v = lookup(handle);
    if (!v || !out) return Code::invalid;
    for (int i = 0; i < ExitKind::words; i++) out[i] = 0;
    v->pending = Pending{};

    hv_return_t r = hv_vcpu_run(v->id);
    if (r != HV_SUCCESS) return fail(r);

    switch (v->exit->reason) {
    case HV_EXIT_REASON_CANCELED:
        return ExitKind::canceled;
    case HV_EXIT_REASON_VTIMER_ACTIVATED:
        return ExitKind::vtimer;
    case HV_EXIT_REASON_EXCEPTION:
        break;
    default:
        out[0] = (uint64_t)v->exit->reason;
        return ExitKind::failed;
    }

    uint64_t esr = v->exit->exception.syndrome;
    uint32_t ec = (uint32_t)(esr >> 26) & 0x3f;
    switch (ec) {
    case 0x24: {   // data abort from a lower EL: an access to unmapped guest memory
        bool isv = (esr >> 24) & 1;
        if (!isv) { out[0] = esr; return ExitKind::failed; }
        uint32_t sas = (uint32_t)(esr >> 22) & 3;
        uint32_t srt = (uint32_t)(esr >> 16) & 0x1f;
        bool write = (esr >> 6) & 1;
        out[0] = v->exit->exception.physical_address;
        out[1] = 1u << sas;
        out[2] = write;
        if (write) {
            uint64_t value = 0;
            if (srt != 31) hv_vcpu_get_reg(v->id, (hv_reg_t)(HV_REG_X0 + srt), &value);
            out[3] = value;
        }
        v->pending.mmioRead = !write;
        v->pending.reg = srt;
        v->pending.advance = true;
        return ExitKind::mmio;
    }
    case 0x16:     // HVC: pc already points past it
    case 0x17: {   // SMC: pc still points at it
        out[0] = ec == 0x16 ? CallKind::hvc : CallKind::smc;
        out[1] = esr & 0xffff;
        for (int i = 0; i < 4; i++) hv_vcpu_get_reg(v->id, (hv_reg_t)(HV_REG_X0 + i), &out[4 + i]);
        v->pending.advance = ec == 0x17;
        return ExitKind::hypercall;
    }
    case 0x18: {   // MSR/MRS to a trapped system register
        bool read = esr & 1;
        uint32_t rt = (uint32_t)(esr >> 5) & 0x1f;
        out[0] = esr & 0x003ffc1e;   // op0, op2, op1, CRn, CRm
        out[2] = !read;
        if (!read && rt != 31) hv_vcpu_get_reg(v->id, (hv_reg_t)(HV_REG_X0 + rt), &out[3]);
        v->pending.mmioRead = read;
        v->pending.reg = rt;
        v->pending.advance = true;
        return ExitKind::sysreg;
    }
    case 0x01:     // WFI / WFE
        v->pending.advance = true;
        return ExitKind::halt;
    case 0x00:
        // An exception with no syndrome at all: seen when hv_vcpus_exit
        // races the vCPU into a WFI (a VM stopping). Nothing to emulate;
        // the caller runs it again, as after a cancel.
        if (esr == 0) return ExitKind::canceled;
        out[0] = esr;
        return ExitKind::failed;
    default:
        out[0] = esr;
        return ExitKind::failed;
    }
}

int32_t hvComplete(int64_t handle, uint64_t value) noexcept {
    Vcpu* v = lookup(handle);
    if (!v) return Code::invalid;
    if (v->pending.mmioRead && v->pending.reg != 31) {
        hv_return_t r = hv_vcpu_set_reg(v->id, (hv_reg_t)(HV_REG_X0 + v->pending.reg), value);
        if (r != HV_SUCCESS) return fail(r);
    }
    if (v->pending.advance) {
        uint64_t pc = 0;
        hv_vcpu_get_reg(v->id, HV_REG_PC, &pc);
        hv_vcpu_set_reg(v->id, HV_REG_PC, pc + 4);
    }
    v->pending = Pending{};
    return Code::ok;
}

int32_t hvGetReg(int64_t handle, int32_t reg, uint64_t* out) noexcept {
    Vcpu* v = lookup(handle);
    if (!v || !out) return Code::invalid;
    hv_reg_t r;
    if (gpr(reg, &r)) return fail(hv_vcpu_get_reg(v->id, r, out));
    if (reg == RegArm64::sp) return fail(hv_vcpu_get_sys_reg(v->id, HV_SYS_REG_SP_EL1, out));
    if (reg == RegArm64::mpidr) return fail(hv_vcpu_get_sys_reg(v->id, HV_SYS_REG_MPIDR_EL1, out));
    if (reg == RegArm64::elr_el1) return fail(hv_vcpu_get_sys_reg(v->id, HV_SYS_REG_ELR_EL1, out));
    if (reg == RegArm64::esr_el1) return fail(hv_vcpu_get_sys_reg(v->id, HV_SYS_REG_ESR_EL1, out));
    if (reg == RegArm64::far_el1) return fail(hv_vcpu_get_sys_reg(v->id, HV_SYS_REG_FAR_EL1, out));
    if (reg == RegArm64::vbar_el1) return fail(hv_vcpu_get_sys_reg(v->id, HV_SYS_REG_VBAR_EL1, out));
    if (reg & RegArm64::sysreg) return fail(hv_vcpu_get_sys_reg(v->id, (hv_sys_reg_t)(reg & 0xffff), out));
    return Code::invalid;
}

int32_t hvSetReg(int64_t handle, int32_t reg, uint64_t value) noexcept {
    Vcpu* v = lookup(handle);
    if (!v) return Code::invalid;
    hv_reg_t r;
    if (gpr(reg, &r)) return fail(hv_vcpu_set_reg(v->id, r, value));
    if (reg == RegArm64::sp) return fail(hv_vcpu_set_sys_reg(v->id, HV_SYS_REG_SP_EL1, value));
    if (reg == RegArm64::mpidr) return fail(hv_vcpu_set_sys_reg(v->id, HV_SYS_REG_MPIDR_EL1, value));
    if (reg == RegArm64::elr_el1) return fail(hv_vcpu_set_sys_reg(v->id, HV_SYS_REG_ELR_EL1, value));
    if (reg == RegArm64::esr_el1) return fail(hv_vcpu_set_sys_reg(v->id, HV_SYS_REG_ESR_EL1, value));
    if (reg == RegArm64::far_el1) return fail(hv_vcpu_set_sys_reg(v->id, HV_SYS_REG_FAR_EL1, value));
    if (reg == RegArm64::vbar_el1) return fail(hv_vcpu_set_sys_reg(v->id, HV_SYS_REG_VBAR_EL1, value));
    if (reg & RegArm64::sysreg) return fail(hv_vcpu_set_sys_reg(v->id, (hv_sys_reg_t)(reg & 0xffff), value));
    return Code::invalid;
}

int32_t hvSetSegment(int64_t, int32_t, uint64_t, uint32_t, uint16_t, uint16_t) noexcept {
    return Code::unsupported;
}

int32_t hvUnmaskTimer(int64_t handle) noexcept {
    Vcpu* v = lookup(handle);
    if (!v) return Code::invalid;
    return fail(hv_vcpu_set_vtimer_mask(v->id, false));
}

int32_t hvGicReg(int64_t handle, int32_t kind, uint32_t reg, uint64_t* out) noexcept {
    if (!out) return Code::invalid;
    if (kind == 0) return fail(hv_gic_get_distributor_reg((hv_gic_distributor_reg_t)reg, out));
    Vcpu* v = lookup(handle);
    if (!v) return Code::invalid;
    if (kind == 1) return fail(hv_gic_get_redistributor_reg(v->id, (hv_gic_redistributor_reg_t)reg, out));
    if (kind == 2) return fail(hv_gic_get_icc_reg(v->id, (hv_gic_icc_reg_t)reg, out));
    return Code::invalid;
}

int32_t hvSetGicReg(int64_t handle, int32_t kind, uint32_t reg, uint64_t value) noexcept {
    if (kind == 0) return fail(hv_gic_set_distributor_reg((hv_gic_distributor_reg_t)reg, value));
    Vcpu* v = lookup(handle);
    if (!v) return Code::invalid;
    if (kind == 1) return fail(hv_gic_set_redistributor_reg(v->id, (hv_gic_redistributor_reg_t)reg, value));
    if (kind == 2) return fail(hv_gic_set_icc_reg(v->id, (hv_gic_icc_reg_t)reg, value));
    return Code::invalid;
}

int32_t hvKick(int64_t handle) noexcept {
    Vcpu* v = lookup(handle);
    if (!v) return Code::invalid;
    return fail(hv_vcpus_exit(&v->id, 1));
}

void hvCloseVcpu(int64_t handle) noexcept {
    Vcpu* v = lookup(handle);
    if (!v) return;
    hv_vcpu_destroy(v->id);
    *v = Vcpu{};
}

int32_t lastError() noexcept { return lastErr; }

#else  // Intel Macs: Hypervisor.framework there has no in-kernel APIC; not a target.

int32_t hvProbe(uint64_t*, int32_t) noexcept { return Code::unsupported; }
int64_t hvCreate(int32_t) noexcept { return Code::unsupported; }
int32_t hvCreateIrqChip(int64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t) noexcept { return Code::unsupported; }
int32_t hvMap(int64_t, uint64_t, void*, uint64_t, int32_t) noexcept { return Code::unsupported; }
int32_t hvUnmap(int64_t, uint64_t, uint64_t) noexcept { return Code::unsupported; }
int32_t hvSetIrq(int64_t, uint32_t, bool) noexcept { return Code::unsupported; }
int32_t hvSendMsi(int64_t, uint64_t, uint32_t) noexcept { return Code::unsupported; }
void hvClose(int64_t) noexcept {}
int64_t hvCreateVcpu(int64_t, int32_t) noexcept { return Code::unsupported; }
int32_t hvRun(int64_t, uint64_t*) noexcept { return Code::unsupported; }
int32_t hvComplete(int64_t, uint64_t) noexcept { return Code::unsupported; }
int32_t hvGetReg(int64_t, int32_t, uint64_t*) noexcept { return Code::unsupported; }
int32_t hvSetReg(int64_t, int32_t, uint64_t) noexcept { return Code::unsupported; }
int32_t hvSetSegment(int64_t, int32_t, uint64_t, uint32_t, uint16_t, uint16_t) noexcept { return Code::unsupported; }
int32_t hvUnmaskTimer(int64_t) noexcept { return Code::unsupported; }
int32_t hvGicReg(int64_t, int32_t, uint32_t, uint64_t*) noexcept { return Code::unsupported; }
int32_t hvSetGicReg(int64_t, int32_t, uint32_t, uint64_t) noexcept { return Code::unsupported; }
int32_t hvKick(int64_t) noexcept { return Code::unsupported; }
void hvCloseVcpu(int64_t) noexcept {}
int32_t lastError() noexcept { return 0; }

#endif
