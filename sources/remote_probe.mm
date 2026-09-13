// remote_probe.mm
// Разведка: база UnityFramework + валидность ARM64 кода по RVA
// Лог пишется в /var/mobile/Documents/remote_probe.log

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <cstdio>
#include <cstdarg>

extern int GetGameProcesspid(char*);
extern "C" kern_return_t task_for_pid(mach_port_name_t, int, mach_port_t*);

static mach_port_t gTask      = MACH_PORT_NULL;
static uint64_t    gUnityBase = 0;

static const char* kLogPath = "/var/mobile/Documents/remote_probe.log";

// ─── Лог в файл ─────────────────────────────────────────────────────
static void LogToFile(const char* fmt, ...) {
    FILE* f = fopen(kLogPath, "a");
    if (!f) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fclose(f);
}

// ─── Найти базу UnityFramework через region scan ────────────────────
static uint64_t FindUnityFrameworkBase() {
    if (gUnityBase) return gUnityBase;
    if (gTask == MACH_PORT_NULL) return 0;

    mach_vm_address_t addr = 0x100000000ULL;
    mach_vm_size_t    size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;

    while (1) {
        kern_return_t kr = mach_vm_region(gTask, &addr, &size, VM_REGION_BASIC_INFO_64,
                                          (vm_region_info_t)&info, &infoCnt, &objectName);
        if (kr != KERN_SUCCESS) break;

        uint32_t magic = 0;
        mach_vm_size_t read = 0;
        if (mach_vm_read_overwrite(gTask, addr, 4, (mach_vm_address_t)&magic, &read) == KERN_SUCCESS) {
            if (magic == 0xFEEDFACF) {
                struct mach_header_64 hdr;
                if (mach_vm_read_overwrite(gTask, addr, sizeof(hdr),
                    (mach_vm_address_t)&hdr, &read) == KERN_SUCCESS) {
                    if (size > 100ULL * 1024ULL * 1024ULL) {
                        gUnityBase = addr;
                        LogToFile("[PROBE] UnityFramework base = 0x%llx (size=%llu)",
                                  (unsigned long long)addr, (unsigned long long)size);
                        return addr;
                    }
                }
            }
        }
        addr += size;
    }
    return 0;
}

// ─── Дамп кода в hex ────────────────────────────────────────────────
static void DumpCode(uint64_t absAddr, uint64_t len) {
    if (gTask == MACH_PORT_NULL) return;
    uint8_t buf[64] = {0};
    if (len > 64) len = 64;
    mach_vm_size_t read = 0;
    kern_return_t kr = mach_vm_read_overwrite(gTask, absAddr, len,
                                              (mach_vm_address_t)buf, &read);
    if (kr != KERN_SUCCESS) {
        LogToFile("[PROBE] read 0x%llx FAILED kr=%d", (unsigned long long)absAddr, kr);
        return;
    }
    char hex[256] = {0};
    int pos = 0;
    for (int i = 0; i < (int)len && pos < 240; i++) {
        pos += snprintf(hex + pos, sizeof(hex) - pos, "%02x ", buf[i]);
    }
    LogToFile("[PROBE] code@0x%llx: %s", (unsigned long long)absAddr, hex);
}

// ─── Публичный entry point ──────────────────────────────────────────
extern "C" void ProbeRemote() {
    // Очистить старый лог при старте
    remove(kLogPath);

    LogToFile("========== PROBE START ==========");

    int pid = GetGameProcesspid((char*)"FreeFire");
    if (pid <= 0) {
        LogToFile("[PROBE] FF pid not found");
        return;
    }
    LogToFile("[PROBE] FF pid = %d", pid);

    if (task_for_pid(mach_task_self(), pid, &gTask) != KERN_SUCCESS) {
        LogToFile("[PROBE] task_for_pid FAILED");
        return;
    }
    LogToFile("[PROBE] task port OK");

    uint64_t base = FindUnityFrameworkBase();
    if (!base) {
        LogToFile("[PROBE] unity base NOT found");
        return;
    }

    struct { const char* name; uint64_t rva; } targets[] = {
        { "Player_GetHeadCollider", 0x53C2630 },
        { "Component_GetTransform", 0x91B82E4 },
        { "Transform_GetPosition",  0x91CA5D0 },
        { "get_gameObject",         0x91B8334 },
        { "Physics_Raycast",        0x5FE855C },
        { "GetHp",                  0x543592C },
    };

    for (auto &t : targets) {
        uint64_t abs = base + t.rva;
        LogToFile("[PROBE] === %s  abs=0x%llx ===", t.name, (unsigned long long)abs);
        DumpCode(abs, 32);
    }

    LogToFile("========== PROBE END ==========");
    LogToFile("");
}
