// KVM, for package vm/hypervisor: see hv.cpp.
//
// arm64 and amd64. The interrupt controller, PSCI (arm64) and the LAPIC and
// IOAPIC (amd64) run in the kernel. MMIO completions are written into the
// shared kvm_run page and delivered on the next KVM_RUN.
module;
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/kvm.h>
module vm.hypervisor;

namespace {

constexpr int maxPartitions = 8;
constexpr int maxVcpus = 256;
constexpr int maxSlots = 32;
constexpr int kickSignal = SIGRTMIN + 7;

struct Partition {
    bool used = false;
    int fd = -1;
    int slots = 0;
    uint64_t slotBase[maxSlots] = {};
};

struct Vcpu {
    bool used = false;
    int partition = -1;
    int fd = -1;
    kvm_run* run = nullptr;
    size_t runSize = 0;
    pthread_t thread{};
    bool pendingRead = false;
};

int kvm = -1;
Partition partitions[maxPartitions];
Vcpu vcpus[maxVcpus];
thread_local int32_t lastErr = 0;

int32_t fromErrno() {
    lastErr = errno;
    switch (errno) {
    case ENOENT: case ENODEV: case ENXIO: return Code::unsupported;
    case EACCES: case EPERM: return Code::denied;
    case ENOMEM: return Code::noMemory;
    case EINVAL: return Code::invalid;
    case EEXIST: return Code::exists;
    case EBUSY: return Code::busy;
    default: return Code::generic;
    }
}

int32_t openKvm() {
    if (kvm >= 0) return Code::ok;
    kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) return fromErrno();
    if (ioctl(kvm, KVM_GET_API_VERSION, 0) != KVM_API_VERSION) {
        close(kvm);
        kvm = -1;
        return Code::unsupported;
    }
    // hvKick interrupts KVM_RUN with a signal whose handler does nothing.
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = [](int) {};
    sigaction(kickSignal, &sa, nullptr);
    return Code::ok;
}

Partition* part(int64_t p) {
    if (p < 0 || p >= maxPartitions || !partitions[p].used) return nullptr;
    return &partitions[p];
}

Vcpu* vcpu(int64_t v) {
    if (v < 0 || v >= maxVcpus || !vcpus[v].used) return nullptr;
    return &vcpus[v];
}

#if defined(__aarch64__)
uint64_t coreReg(size_t offset) {
    return KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | (offset / sizeof(uint32_t));
}
bool armReg(int32_t reg, uint64_t* id) {
    if (reg >= 0 && reg <= 30) { *id = coreReg(offsetof(kvm_regs, regs.regs) + reg * 8); return true; }
    if (reg == RegArm64::pc) { *id = coreReg(offsetof(kvm_regs, regs.pc)); return true; }
    if (reg == RegArm64::pstate) { *id = coreReg(offsetof(kvm_regs, regs.pstate)); return true; }
    if (reg == RegArm64::sp) { *id = coreReg(offsetof(kvm_regs, sp_el1)); return true; }
    if (reg == RegArm64::mpidr) { *id = ARM64_SYS_REG(3, 0, 0, 0, 5); return true; }
    return false;
}
#endif

} // namespace

int32_t hvProbe(uint64_t* out, int32_t count) noexcept {
    if (!out || count < ProbeWord::count) return Code::invalid;
    int32_t rc = openKvm();
    if (rc < 0) return rc;
    int max = ioctl(kvm, KVM_CHECK_EXTENSION, KVM_CAP_MAX_VCPUS);
#if defined(__aarch64__)
    out[ProbeWord::arch] = ArchCode::arm64;
    out[ProbeWord::hyperV] = 0;
    int ipa = ioctl(kvm, KVM_CHECK_EXTENSION, KVM_CAP_ARM_VM_IPA_SIZE);
    out[ProbeWord::physicalAddressBits] = ipa > 0 ? ipa : 40;
#else
    out[ProbeWord::arch] = ArchCode::amd64;
    out[ProbeWord::hyperV] = ioctl(kvm, KVM_CHECK_EXTENSION, KVM_CAP_HYPERV) > 0;
    out[ProbeWord::physicalAddressBits] = 46;   // TODO: CPUID 0x80000008
#endif
    out[ProbeWord::maxVcpus] = max > 0 ? (max < maxVcpus ? max : maxVcpus) : 1;
    out[ProbeWord::inKernelIrqChip] = 1;
    out[ProbeWord::doorbells] = ioctl(kvm, KVM_CHECK_EXTENSION, KVM_CAP_IOEVENTFD) > 0;
    out[ProbeWord::dirtyLogging] = 1;
    out[ProbeWord::partitionsPerProcess] = maxPartitions;
    return Code::ok;
}

int64_t hvCreate(int32_t vcpuCount) noexcept {
    (void)vcpuCount;
    int32_t rc = openKvm();
    if (rc < 0) return rc;
    for (int i = 0; i < maxPartitions; i++) {
        if (partitions[i].used) continue;
        unsigned long type = 0;
#if defined(__aarch64__)
        int ipa = ioctl(kvm, KVM_CHECK_EXTENSION, KVM_CAP_ARM_VM_IPA_SIZE);
        if (ipa > 0) type = KVM_VM_TYPE_ARM_IPA_SIZE(ipa);
#endif
        int fd = ioctl(kvm, KVM_CREATE_VM, type);
        if (fd < 0) return fromErrno();
        partitions[i] = Partition{};
        partitions[i].used = true;
        partitions[i].fd = fd;
        return i;
    }
    return Code::noMemory;
}

int32_t hvCreateIrqChip(int64_t p, uint64_t distributor, uint64_t redistributor,
                        uint64_t msiBase, uint32_t msiFirst, uint32_t msiCount) noexcept {
    (void)msiFirst; (void)msiCount;
    Partition* pt = part(p);
    if (!pt) return Code::invalid;
#if defined(__aarch64__)
    kvm_create_device dev{};
    dev.type = KVM_DEV_TYPE_ARM_VGIC_V3;
    if (ioctl(pt->fd, KVM_CREATE_DEVICE, &dev) < 0) return fromErrno();
    kvm_device_attr attr{};
    attr.group = KVM_DEV_ARM_VGIC_GRP_ADDR;
    attr.attr = KVM_VGIC_V3_ADDR_TYPE_DIST;
    attr.addr = (uint64_t)(uintptr_t)&distributor;
    if (ioctl(dev.fd, KVM_SET_DEVICE_ATTR, &attr) < 0) return fromErrno();
    attr.attr = KVM_VGIC_V3_ADDR_TYPE_REDIST;
    attr.addr = (uint64_t)(uintptr_t)&redistributor;
    if (ioctl(dev.fd, KVM_SET_DEVICE_ATTR, &attr) < 0) return fromErrno();
    if (msiBase != 0) {
        kvm_create_device its{};
        its.type = KVM_DEV_TYPE_ARM_VGIC_ITS;
        if (ioctl(pt->fd, KVM_CREATE_DEVICE, &its) < 0) return fromErrno();
        kvm_device_attr a{};
        a.group = KVM_DEV_ARM_VGIC_GRP_ADDR;
        a.attr = KVM_VGIC_ITS_ADDR_TYPE;
        a.addr = (uint64_t)(uintptr_t)&msiBase;
        if (ioctl(its.fd, KVM_SET_DEVICE_ATTR, &a) < 0) return fromErrno();
    }
    // KVM_DEV_ARM_VGIC_CTRL_INIT happens once every vCPU exists: the
    // Vertex side calls hvCreateIrqChip after hvCreateVcpu on arm64 KVM.
    kvm_device_attr init{};
    init.group = KVM_DEV_ARM_VGIC_GRP_CTRL;
    init.attr = KVM_DEV_ARM_VGIC_CTRL_INIT;
    if (ioctl(dev.fd, KVM_SET_DEVICE_ATTR, &init) < 0) return fromErrno();
    return Code::ok;
#else
    (void)distributor; (void)redistributor; (void)msiBase;
    if (ioctl(pt->fd, KVM_CREATE_IRQCHIP, 0) < 0) return fromErrno();
    return Code::ok;
#endif
}

int32_t hvMap(int64_t p, uint64_t gpa, void* host, uint64_t count, int32_t access) noexcept {
    Partition* pt = part(p);
    if (!pt || !host || pt->slots >= maxSlots) return Code::invalid;
    kvm_userspace_memory_region region{};
    region.slot = (uint32_t)pt->slots;
    region.flags = (access & AccessBit::write) ? 0 : KVM_MEM_READONLY;
    region.guest_phys_addr = gpa;
    region.memory_size = count;
    region.userspace_addr = (uint64_t)(uintptr_t)host;
    if (ioctl(pt->fd, KVM_SET_USER_MEMORY_REGION, &region) < 0) return fromErrno();
    pt->slotBase[pt->slots++] = gpa;
    return Code::ok;
}

int32_t hvUnmap(int64_t p, uint64_t gpa, uint64_t count) noexcept {
    (void)count;
    Partition* pt = part(p);
    if (!pt) return Code::invalid;
    for (int i = 0; i < pt->slots; i++) {
        if (pt->slotBase[i] != gpa) continue;
        kvm_userspace_memory_region region{};
        region.slot = (uint32_t)i;
        region.guest_phys_addr = gpa;
        region.memory_size = 0;   // size 0 deletes the slot
        if (ioctl(pt->fd, KVM_SET_USER_MEMORY_REGION, &region) < 0) return fromErrno();
        return Code::ok;
    }
    return Code::invalid;
}

int32_t hvSetIrq(int64_t p, uint32_t line, bool level) noexcept {
    Partition* pt = part(p);
    if (!pt) return Code::invalid;
    kvm_irq_level irq{};
#if defined(__aarch64__)
    irq.irq = (KVM_ARM_IRQ_TYPE_SPI << KVM_ARM_IRQ_TYPE_SHIFT) | line;
#else
    irq.irq = line;
#endif
    irq.level = level ? 1 : 0;
    if (ioctl(pt->fd, KVM_IRQ_LINE, &irq) < 0) return fromErrno();
    return Code::ok;
}

int32_t hvSendMsi(int64_t p, uint64_t address, uint32_t data) noexcept {
    Partition* pt = part(p);
    if (!pt) return Code::invalid;
    kvm_msi msi{};
    msi.address_lo = (uint32_t)address;
    msi.address_hi = (uint32_t)(address >> 32);
    msi.data = data;
    if (ioctl(pt->fd, KVM_SIGNAL_MSI, &msi) < 0) return fromErrno();
    return Code::ok;
}

void hvClose(int64_t p) noexcept {
    Partition* pt = part(p);
    if (!pt) return;
    for (auto& v : vcpus) {
        if (v.used && v.partition == p) {
            munmap(v.run, v.runSize);
            close(v.fd);
            v = Vcpu{};
        }
    }
    close(pt->fd);
    *pt = Partition{};
}

int64_t hvCreateVcpu(int64_t p, int32_t id) noexcept {
    Partition* pt = part(p);
    if (!pt || id < 0) return Code::invalid;
    for (int i = 0; i < maxVcpus; i++) {
        if (vcpus[i].used) continue;
        int fd = ioctl(pt->fd, KVM_CREATE_VCPU, (unsigned long)id);
        if (fd < 0) return fromErrno();
        int size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
        void* run = mmap(nullptr, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (run == MAP_FAILED) { close(fd); return fromErrno(); }
#if defined(__aarch64__)
        kvm_vcpu_init init{};
        ioctl(pt->fd, KVM_ARM_PREFERRED_TARGET, &init);
        init.features[0] |= 1u << KVM_ARM_VCPU_PSCI_0_2;
        if (id != 0) init.features[0] |= 1u << KVM_ARM_VCPU_POWER_OFF;   // secondaries wait for CPU_ON
        if (ioctl(fd, KVM_ARM_VCPU_INIT, &init) < 0) {
            munmap(run, (size_t)size);
            close(fd);
            return fromErrno();
        }
#endif
        vcpus[i] = Vcpu{};
        vcpus[i].used = true;
        vcpus[i].partition = (int)p;
        vcpus[i].fd = fd;
        vcpus[i].run = (kvm_run*)run;
        vcpus[i].runSize = (size_t)size;
        vcpus[i].thread = pthread_self();
        return i;
    }
    return Code::noMemory;
}

int32_t hvRun(int64_t handle, uint64_t* out) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v || !out) return Code::invalid;
    for (int i = 0; i < ExitKind::words; i++) out[i] = 0;
    v->thread = pthread_self();
    v->pendingRead = false;

    if (ioctl(v->fd, KVM_RUN, 0) < 0) {
        if (errno == EINTR || errno == EAGAIN) {
            v->run->immediate_exit = 0;
            return ExitKind::canceled;
        }
        return fromErrno();
    }

    kvm_run* r = v->run;
    switch (r->exit_reason) {
    case KVM_EXIT_MMIO: {
        out[0] = r->mmio.phys_addr;
        out[1] = r->mmio.len;
        out[2] = r->mmio.is_write;
        if (r->mmio.is_write) {
            uint64_t value = 0;
            memcpy(&value, r->mmio.data, r->mmio.len <= 8 ? r->mmio.len : 8);
            out[3] = value;
        }
        v->pendingRead = !r->mmio.is_write;
        return ExitKind::mmio;
    }
    case KVM_EXIT_IO: {
        out[0] = r->io.port;
        out[1] = r->io.size;
        out[2] = r->io.direction == KVM_EXIT_IO_OUT;
        if (r->io.direction == KVM_EXIT_IO_OUT) {
            uint32_t value = 0;
            memcpy(&value, (uint8_t*)r + r->io.data_offset, r->io.size <= 4 ? r->io.size : 4);
            out[3] = value;
        }
        v->pendingRead = r->io.direction == KVM_EXIT_IO_IN;
        return ExitKind::io;
    }
    case KVM_EXIT_HLT:
        return ExitKind::halt;
    case KVM_EXIT_SHUTDOWN:
        return ExitKind::shutdown;
    case KVM_EXIT_SYSTEM_EVENT:
        out[0] = r->system_event.type;   // KVM_SYSTEM_EVENT_SHUTDOWN / RESET
        return ExitKind::shutdown;
    case KVM_EXIT_INTR:
        return ExitKind::canceled;
    default:
        out[0] = r->exit_reason;
        return ExitKind::failed;
    }
}

int32_t hvComplete(int64_t handle, uint64_t value) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
    if (!v->pendingRead) return Code::ok;
    kvm_run* r = v->run;
    if (r->exit_reason == KVM_EXIT_MMIO) {
        memcpy(r->mmio.data, &value, r->mmio.len <= 8 ? r->mmio.len : 8);
    } else if (r->exit_reason == KVM_EXIT_IO) {
        memcpy((uint8_t*)r + r->io.data_offset, &value, r->io.size <= 4 ? r->io.size : 4);
    }
    v->pendingRead = false;
    return Code::ok;
}

int32_t hvGetReg(int64_t handle, int32_t reg, uint64_t* out) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v || !out) return Code::invalid;
#if defined(__aarch64__)
    uint64_t id;
    if (!armReg(reg, &id)) return Code::invalid;
    kvm_one_reg one{ id, (uint64_t)(uintptr_t)out };
    if (ioctl(v->fd, KVM_GET_ONE_REG, &one) < 0) return fromErrno();
    return Code::ok;
#else
    if (reg <= RegAmd64::rflags) {
        kvm_regs regs{};
        if (ioctl(v->fd, KVM_GET_REGS, &regs) < 0) return fromErrno();
        uint64_t all[18] = { regs.rax, regs.rcx, regs.rdx, regs.rbx, regs.rsp, regs.rbp, regs.rsi, regs.rdi,
                             regs.r8, regs.r9, regs.r10, regs.r11, regs.r12, regs.r13, regs.r14, regs.r15,
                             regs.rip, regs.rflags };
        if (reg < 0) return Code::invalid;
        *out = all[reg];
        return Code::ok;
    }
    kvm_sregs s{};
    if (ioctl(v->fd, KVM_GET_SREGS, &s) < 0) return fromErrno();
    switch (reg) {
    case RegAmd64::cr0: *out = s.cr0; return Code::ok;
    case RegAmd64::cr3: *out = s.cr3; return Code::ok;
    case RegAmd64::cr4: *out = s.cr4; return Code::ok;
    case RegAmd64::efer: *out = s.efer; return Code::ok;
    default: return Code::invalid;
    }
#endif
}

int32_t hvSetReg(int64_t handle, int32_t reg, uint64_t value) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
#if defined(__aarch64__)
    uint64_t id;
    if (!armReg(reg, &id)) return Code::invalid;
    kvm_one_reg one{ id, (uint64_t)(uintptr_t)&value };
    if (ioctl(v->fd, KVM_SET_ONE_REG, &one) < 0) return fromErrno();
    return Code::ok;
#else
    if (reg >= 0 && reg <= RegAmd64::rflags) {
        kvm_regs regs{};
        if (ioctl(v->fd, KVM_GET_REGS, &regs) < 0) return fromErrno();
        uint64_t* all[18] = { &regs.rax, &regs.rcx, &regs.rdx, &regs.rbx, &regs.rsp, &regs.rbp, &regs.rsi, &regs.rdi,
                              &regs.r8, &regs.r9, &regs.r10, &regs.r11, &regs.r12, &regs.r13, &regs.r14, &regs.r15,
                              &regs.rip, &regs.rflags };
        *all[reg] = value;
        if (ioctl(v->fd, KVM_SET_REGS, &regs) < 0) return fromErrno();
        return Code::ok;
    }
    kvm_sregs s{};
    if (ioctl(v->fd, KVM_GET_SREGS, &s) < 0) return fromErrno();
    switch (reg) {
    case RegAmd64::cr0: s.cr0 = value; break;
    case RegAmd64::cr3: s.cr3 = value; break;
    case RegAmd64::cr4: s.cr4 = value; break;
    case RegAmd64::efer: s.efer = value; break;
    default: return Code::invalid;
    }
    if (ioctl(v->fd, KVM_SET_SREGS, &s) < 0) return fromErrno();
    return Code::ok;
#endif
}

int32_t hvSetSegment(int64_t handle, int32_t seg, uint64_t base, uint32_t limit,
                     uint16_t selector, uint16_t attributes) noexcept {
#if defined(__aarch64__)
    (void)handle; (void)seg; (void)base; (void)limit; (void)selector; (void)attributes;
    return Code::unsupported;
#else
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
    kvm_sregs s{};
    if (ioctl(v->fd, KVM_GET_SREGS, &s) < 0) return fromErrno();
    if (seg == SegAmd64::gdtr || seg == SegAmd64::idtr) {
        kvm_dtable& t = seg == SegAmd64::gdtr ? s.gdt : s.idt;
        t.base = base;
        t.limit = (uint16_t)limit;
    } else {
        kvm_segment* all[8] = { &s.cs, &s.ds, &s.es, &s.fs, &s.gs, &s.ss, &s.tr, &s.ldt };
        if (seg < 0 || seg > SegAmd64::ldtr) return Code::invalid;
        kvm_segment& g = *all[seg];
        // attributes are the VMX access-rights layout: type, s, dpl, p, avl, l, db, g.
        g.base = base;
        g.limit = limit;
        g.selector = selector;
        g.type = attributes & 0xf;
        g.s = (attributes >> 4) & 1;
        g.dpl = (attributes >> 5) & 3;
        g.present = (attributes >> 7) & 1;
        g.avl = (attributes >> 12) & 1;
        g.l = (attributes >> 13) & 1;
        g.db = (attributes >> 14) & 1;
        g.g = (attributes >> 15) & 1;
        g.unusable = g.present ? 0 : 1;
    }
    if (ioctl(v->fd, KVM_SET_SREGS, &s) < 0) return fromErrno();
    return Code::ok;
#endif
}

int32_t hvUnmaskTimer(int64_t) noexcept { return Code::ok; }
int32_t hvGicReg(int64_t, int32_t, uint32_t, uint64_t*) noexcept { return Code::unsupported; }

int32_t hvKick(int64_t handle) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return Code::invalid;
    __atomic_store_n(&v->run->immediate_exit, 1, __ATOMIC_RELEASE);
    pthread_kill(v->thread, kickSignal);
    return Code::ok;
}

void hvCloseVcpu(int64_t handle) noexcept {
    Vcpu* v = vcpu(handle);
    if (!v) return;
    munmap(v->run, v->runSize);
    close(v->fd);
    *v = Vcpu{};
}

int32_t lastError() noexcept { return lastErr; }
