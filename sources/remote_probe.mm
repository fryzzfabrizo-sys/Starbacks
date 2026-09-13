// remote_probe.mm
// TEST 1: наша функция add(5,7) — проверка инфры
// TEST 2: GetHp(localPlayer) — проверка IL2CPP

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach/thread_act.h>
#include <mach/arm/thread_status.h>
#include <mach-o/loader.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <unistd.h>

extern uint64_t Moudule_Base;
uint64_t getMatchGame(uint64_t);
uint64_t getMatch(uint64_t);
uint64_t getLocalPlayer(uint64_t);
int get_CurHP(uint64_t);
int get_MaxHP(uint64_t);

extern int GetGameProcesspid(char*);
extern "C" kern_return_t task_for_pid(mach_port_name_t, int, mach_port_t*);

static mach_port_t gTask = MACH_PORT_NULL;
static uint64_t gUnityBase = 0;
static const char* kLogPath = "/var/mobile/Documents/remote_probe.log";

static void LogToFile(const char* fmt, ...) {
    FILE* f = fopen(kLogPath, "a");
    if (!f) return;
    va_list args; va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fclose(f);
}

static bool VMRead(mach_port_t t, uint64_t a, void* o, size_t s) {
    vm_size_t out = 0;
    return vm_read_overwrite(t, (vm_address_t)a, (vm_size_t)s, (vm_address_t)o, &out) == KERN_SUCCESS && out == s;
}
static bool VMWrite(mach_port_t t, uint64_t a, const void* in, size_t s) {
    return vm_write(t, (vm_address_t)a, (vm_offset_t)in, (mach_msg_type_number_t)s) == KERN_SUCCESS;
}
static uint64_t VMAlloc(mach_port_t t, size_t s) {
    vm_address_t a = 0;
    if (vm_allocate(t, &a, (vm_size_t)s, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return 0;
    vm_protect(t, a, (vm_size_t)s, FALSE, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    return a;
}

static uint64_t FindUnityBase() {
    if (gUnityBase) return gUnityBase;
    vm_address_t addr = 0x100000000ULL;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    while (1) {
        kern_return_t kr = vm_region_64(gTask, &addr, &size, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS) break;
        uint32_t magic = 0;
        if (VMRead(gTask, addr, &magic, 4) && magic == 0xFEEDFACF) {
            if (size > 100ULL*1024*1024) { gUnityBase = addr; return addr; }
        }
        addr += size;
    }
    return 0;
}

// Вызов: PC=func, LR=landing(wfe-loop), args X0/X1, SP=stack
// Возврат: X0 на момент остановки потока на landing
static uint64_t RemoteCall2(mach_port_t task, uint64_t func, uint64_t a0, uint64_t a1) {
    uint64_t stack = VMAlloc(task, 65536);
    if (!stack) { LogToFile("[RC] stack alloc FAILED"); return 0; }
    uint64_t sp = (stack + 65536 - 0x10) & ~0xFULL;

    uint64_t landing = VMAlloc(task, 0x1000);
    if (!landing) { LogToFile("[RC] landing alloc FAILED"); return 0; }
    // wfe; b .-4  = бесконечный wait-loop
    uint32_t loopInsn[2] = { 0xD503205F, 0x17FFFFFF };
    VMWrite(task, landing, loopInsn, 8);

    arm_thread_state64_t ts;
    memset(&ts, 0, sizeof(ts));
    ts.__x[0] = a0;
    ts.__x[1] = a1;
    ts.__sp   = sp;
    ts.__lr   = landing;
    ts.__pc   = func;

    thread_act_t th;
    kern_return_t tkr = thread_create_running(task,
                                              ARM_THREAD_STATE64,
                                              (thread_state_t)&ts,
                                              ARM_THREAD_STATE64_COUNT,
                                              &th);
    if (tkr != KERN_SUCCESS) {
        LogToFile("[RC] thread_create FAILED kr=%d", tkr);
        return 0;
    }

    uint64_t result = 0;
    for (int i = 0; i < 500; i++) {
        usleep(1000);
        arm_thread_state64_t cur;
        mach_msg_type_number_t c = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &c) != KERN_SUCCESS) break;
        // Маскируем PAC-биты (старшие 16 бит)
        uint64_t pcMask = cur.__pc & 0x0000FFFFFFFFFFFFULL;
        uint64_t lMask  = landing & 0x0000FFFFFFFFFFFFULL;
        if (pcMask == lMask) {
            usleep(3000);
            c = ARM_THREAD_STATE64_COUNT;
            thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &c);
            result = cur.__x[0];
            break;
        }
    }

    // НЕ убиваем поток. Оставляем его в wfe-loop. Процесс сам уберёт.
    return result;
}

extern "C" void ProbeRemote() {
    remove(kLogPath);
    LogToFile("========== REMOTE CALL TEST 3 ==========");

    int pid = GetGameProcesspid((char*)"FreeFire");
    if (pid <= 0) { LogToFile("pid not found"); return; }
    LogToFile("pid = %d", pid);

    if (task_for_pid(mach_task_self(), pid, &gTask) != KERN_SUCCESS) {
        LogToFile("task_for_pid FAILED");
        return;
    }
    LogToFile("task OK");

    if (!FindUnityBase()) { LogToFile("unity base not found"); return; }
    LogToFile("unity base = 0x%llx", (unsigned long long)gUnityBase);

    // ─── TEST 1: наша собственная функция add(x0,x1) ───────────
    LogToFile("[TEST1] call our own add function");
    uint64_t codePage = VMAlloc(gTask, 0x1000);
    // add x0, x0, x1  = 0x8B010000
    // ret             = 0xD65F03C0
    uint32_t addFunc[2] = { 0x8B010000, 0xD65F03C0 };
    VMWrite(gTask, codePage, addFunc, 8);
    LogToFile("[TEST1] add func addr = 0x%llx", (unsigned long long)codePage);

    uint64_t r1 = RemoteCall2(gTask, codePage, 5, 7);
    LogToFile("[TEST1] add(5, 7) = %llu  (expect 12)", (unsigned long long)r1);

    // ─── TEST 2: GetHp(localPlayer) ────────────────────────────
    LogToFile("[TEST2] call GetHp(localPlayer)");
    uint64_t matchGame = getMatchGame(Moudule_Base);
    LogToFile("matchGame = 0x%llx", (unsigned long long)matchGame);
    if (!matchGame) { LogToFile("no match — запускай в бою"); goto done; }

    uint64_t match = getMatch(matchGame);
    if (!match) { LogToFile("no match ptr"); goto done; }
    LogToFile("match = 0x%llx", (unsigned long long)match);

    uint64_t local = getLocalPlayer(match);
    if (!local) { LogToFile("no local player"); goto done; }
    LogToFile("localPlayer = 0x%llx", (unsigned long long)local);

    int hpDirect    = get_CurHP(local);
    int hpMaxDirect = get_MaxHP(local);
    LogToFile("direct: HP = %d / %d", hpDirect, hpMaxDirect);

    uint64_t getHpAddr = gUnityBase + 0x543592C;
    LogToFile("GetHp addr = 0x%llx", (unsigned long long)getHpAddr);

    uint64_t r2 = RemoteCall2(gTask, getHpAddr, local, 0);
    LogToFile("[TEST2] remote GetHp = %lld", (long long)r2);

    if ((int)r2 == hpDirect)
        LogToFile("[TEST2] *** MATCH — WORKS ***");
    else
        LogToFile("[TEST2] mismatch direct=%d remote=%lld", hpDirect, (long long)r2);

done:
    LogToFile("========== DONE ==========");
    LogToFile("");
}
