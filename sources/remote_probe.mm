// remote_probe.mm
// Remote call test: GetHp(nullptr) через thread_create_running
// Landing pad = wfe (wait for event) — паркует поток без SIGTRAP
// Лог в /var/mobile/Documents/remote_probe.log

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_region.h>
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <unistd.h>

extern int GetGameProcesspid(char*);
extern "C" kern_return_t task_for_pid(mach_port_name_t, int, mach_port_t*);

static mach_port_t gTask      = MACH_PORT_NULL;
static uint64_t    gUnityBase = 0;

static const char* kLogPath = "/var/mobile/Documents/remote_probe.log";

// ─── Лог ────────────────────────────────────────────────────────────
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

// ─── VM API ─────────────────────────────────────────────────────────
static bool VMRead(mach_port_t task, uint64_t addr, void* out, size_t size) {
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(task,
                                         (vm_address_t)addr,
                                         (vm_size_t)size,
                                         (vm_address_t)out,
                                         &outSize);
    return kr == KERN_SUCCESS && outSize == size;
}

static bool VMWrite(mach_port_t task, uint64_t addr, const void* in, size_t size) {
    kern_return_t kr = vm_write(task,
                                (vm_address_t)addr,
                                (vm_offset_t)in,
                                (mach_msg_type_number_t)size);
    return kr == KERN_SUCCESS;
}

static uint64_t VMAlloc(mach_port_t task, size_t size) {
    vm_address_t addr = 0;
    kern_return_t kr = vm_allocate(task, &addr, (vm_size_t)size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return 0;
    vm_protect(task, addr, (vm_size_t)size, FALSE,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    return addr;
}

// ─── Найти базу UnityFramework ──────────────────────────────────────
static uint64_t FindUnityFrameworkBase() {
    if (gUnityBase) return gUnityBase;
    if (gTask == MACH_PORT_NULL) return 0;

    vm_address_t addr = 0x100000000ULL;
    vm_size_t    size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;

    while (1) {
        kern_return_t kr = vm_region_64(gTask, &addr, &size, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &infoCnt, &objectName);
        if (kr != KERN_SUCCESS) break;

        uint32_t magic = 0;
        if (VMRead(gTask, addr, &magic, 4)) {
            if (magic == 0xFEEDFACF) {
                struct mach_header_64 hdr;
                if (VMRead(gTask, addr, &hdr, sizeof(hdr))) {
                    if (size > 100ULL * 1024ULL * 1024ULL) {
                        gUnityBase = addr;
                        LogToFile("[PROBE] UnityFramework base = 0x%llx",
                                  (unsigned long long)addr);
                        return addr;
                    }
                }
            }
        }
        addr += size;
    }
    return 0;
}

// ─── Remote call: один аргумент uint64, возврат uint64 ─────────────
static uint64_t RemoteCall1(mach_port_t task,
                            uint64_t funcAddr,
                            uint64_t arg0)
{
    // 1) Стек 64 KB
    uint64_t stackBase = VMAlloc(task, 65536);
    if (!stackBase) {
        LogToFile("[RC] stack alloc FAILED");
        return 0;
    }

    // 2) SP — на верхушке, 16-байтовое выравнивание
    uint64_t sp = (stackBase + 65536 - 0x10) & ~0xFULL;

    // 3) Landing pad — выделяем 0x10 байт и кладём туда wfe
    uint64_t landing = VMAlloc(task, 0x10);
    if (!landing) {
        LogToFile("[RC] landing alloc FAILED");
        return 0;
    }

    // ARM64: "wfe" = wait for event. Паркует поток без сигнала.
    // Кодирование: 0xD503205F → little-endian bytes: 5F 20 03 D5
    uint32_t wfeInsn = 0xD503205F;
    VMWrite(task, landing, &wfeInsn, 4);

    // 4) Состояние потока
    arm_thread_state64_t ts;
    memset(&ts, 0, sizeof(ts));
    ts.__x[0]  = arg0;               // X0 = Player*
    ts.__x[1]  = 0;
    ts.__x[2]  = 0;
    ts.__x[3]  = 0;
    ts.__sp    = sp;
    ts.__lr    = landing;            // куда вернуться
    ts.__pc    = funcAddr;           // что вызвать
    ts.__cpsr  = 0;                  // user mode

    // 5) Создать поток
    thread_act_t thread;
    kern_return_t kr = thread_create_running(task,
                                             ARM_THREAD_STATE64,
                                             (thread_state_t)&ts,
                                             ARM_THREAD_STATE64_COUNT,
                                             &thread);
    if (kr != KERN_SUCCESS) {
        LogToFile("[RC] thread_create_running FAILED kr=%d", kr);
        return 0;
    }

    // 6) Ждём до 500 мс — поток должен встать на wfe
    uint64_t result = 0;
    for (int i = 0; i < 500; i++) {
        usleep(1000);

        arm_thread_state64_t cur;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        kern_return_t gkr = thread_get_state(thread, ARM_THREAD_STATE64,
                                             (thread_state_t)&cur, &cnt);
        if (gkr != KERN_SUCCESS) break;

        // На wfe PC остаётся ровно на landing (нет продвижения).
        // Как только оказались тут — X0 уже содержит возврат из GetHp.
        if (cur.__pc == landing) {
            // Даём CPU 5 мс дойти до wfe
            usleep(5000);
            // Ещё раз читаем — на случай если PC сдвинулся
            cnt = ARM_THREAD_STATE64_COUNT;
            thread_get_state(thread, ARM_THREAD_STATE64,
                             (thread_state_t)&cur, &cnt);
            result = cur.__x[0];
            break;
        }
    }

    // 7) Убиваем поток
    thread_terminate(thread);

    // 8) Освобождаем память
    vm_deallocate(task, (vm_address_t)stackBase, 65536);
    vm_deallocate(task, (vm_address_t)landing,   0x10);

    return result;
}

// ─── Публичный entry point ──────────────────────────────────────────
extern "C" void ProbeRemote() {
    remove(kLogPath);
    LogToFile("========== REMOTE CALL TEST ==========");

    int pid = GetGameProcesspid((char*)"FreeFire");
    if (pid <= 0) { LogToFile("[PROBE] pid not found"); return; }
    LogToFile("[PROBE] FF pid = %d", pid);

    if (task_for_pid(mach_task_self(), pid, &gTask) != KERN_SUCCESS) {
        LogToFile("[PROBE] task_for_pid FAILED");
        return;
    }
    LogToFile("[PROBE] task port OK");

    uint64_t base = FindUnityFrameworkBase();
    if (!base) { LogToFile("[PROBE] unity base NOT found"); return; }

    uint64_t getHpAddr = base + 0x543592C;
    LogToFile("[RC] GetHp addr = 0x%llx", (unsigned long long)getHpAddr);

    LogToFile("[RC] calling GetHp(nullptr)...");
    uint64_t res = RemoteCall1(gTask, getHpAddr, 0);
    LogToFile("[RC] GetHp(nullptr) = %llu (0x%llx)",
              (unsigned long long)res, (unsigned long long)res);

    LogToFile("========== DONE ==========");
    LogToFile("");
}
