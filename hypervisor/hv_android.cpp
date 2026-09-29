// Android, for package vm/hypervisor: see hv.cpp.
//
// Apps can't open /dev/kvm. Protected VMs go through the Android
// Virtualization Framework, which is a separate, privileged service rather
// than a hypervisor API. Every export says so.
module;
#include <stdint.h>
module vm.hypervisor;

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
int32_t hvKick(int64_t) noexcept { return Code::unsupported; }
void hvCloseVcpu(int64_t) noexcept {}
int32_t lastError() noexcept { return 0; }
