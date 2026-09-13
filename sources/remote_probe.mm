// remote_probe.mm
// Диагностическая версия — пошаговый дамп состояния потока

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
static uint64_t VMAlloc(mach_port_t t, size_t s, int *outKr) {
    vm_address_t a = 0;
    kern_return_t kr = vm_allocate(t, &a, (vm_size_t)s, VM_FLAGS_ANYWHERE);
    if (outKr) *outKr = kr;
    if (kr != KERN_SUCCESS) return 0;
    kern_return_t pkr = vm_protect(t, a, (vm_size_t)s, FALSE,
                                   VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    if (outKr) *outKr = pkr;
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

static uint64_t RemoteCall2(mach_port_t task, uint64_t func, uint64_t a0, uint64_t a1) {
    LogToFile("[RC] --- RemoteCall2 start func=0x%llx arg0=0x%llx ---",
              (unsigned long long)func, (unsigned long long)a0);

    int krAlloc = 0;
    uint64_t stack = VMAlloc(task, 65536, &krAlloc);
    LogToFile("[RC] stack alloc = 0x%llx (kr=%d)", (unsigned long long)stack, krAlloc);
    if (!stack) return 0;
    uint64_t sp = (stack + 65536 - 0x10) & ~0xFULL;

    uint64_t landing = VMAlloc(task, 0x1000, &krAlloc);
    LogToFile("[RC] landing alloc = 0x%llx (kr=%d)", (unsigned long long)landing, krAlloc);
    if (!landing) return 0;

    // wfe; b .-4 — wait forever
    uint32_t loopInsn[2] = { 0xD503205F, 0x17FFFFFF };
    bool wOK = VMWrite(task, landing, loopInsn, 8);
    LogToFile("[RC] landing write = %s", wOK ? "OK" : "FAIL");

    uint32_t check[2] = {0};
    VMRead(task, landing, check, 8);
    LogToFile("[RC] landing verify: %08x %08x", check[0], check[1]);

    uint32_t codeCheck[2] = {0};
    VMRead(task, func, codeCheck, 8);
    LogToFile("[RC] func code: %08x %08x", codeCheck[0], codeCheck[1]);

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
    LogToFile("[RC] thread_create kr=%d th=0x%x", tkr, th);
    if (tkr != KERN_SUCCESS) return 0;

    uint64_t result = 0;
    uint64_t lastPC = 0;
    int stuck = 0;

    for (int i = 0; i < 100; i++) {
        usleep(1000);
        arm_thread_state64_t cur;
        mach_msg_type_number_t c = ARM_THREAD_STATE64_COUNT;
        kern_return_t gkr = thread_get_state(th, ARM_THREAD_STATE64,
                                             (thread_state_t)&cur, &c);
        if (gkr != KERN_SUCCESS) {
            LogToFile("[RC] iter %d: get_state FAILED kr=%d", i, gkr);
            break;
        }

        uint64_t pcM = cur.__pc  & 0x0000FFFFFFFFFFFFULL;
        uint64_t lM  = landing   & 0x0000FFFFFFFFFFFFULL;
        uint64_t fM  = func      & 0x0000FFFFFFFFFFFFULL;

        if (i < 5 || pcM == lM || pcM == fM || (i % 10 == 0)) {
            LogToFile("[RC] iter %d: PC=0x%llx X0=0x%llx X1=0x%llx X29=0x%llx SP=0x%llx",
                      i,
                      (unsigned long long)pcM,
                      (unsigned long long)cur.__x[0],
                      (unsigned long long)cur.__x[1],
                      (unsigned long long)cur.__x[29],
                      (unsigned long long)cur.__sp);
        }

        if (pcM == lM) {
            usleep(5000);
            c = ARM_THREAD_STATE64_COUNT;
            thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &c);
            result = cur.__x[0];
            LogToFile("[RC] STOPPED at landing. X0 = 0x%llx", (unsigned long long)result);
            break;
        }

        if (pcM == lastPC) stuck++;
        else stuck = 0;
        lastPC = pcM;

        if (stuck > 20) {
            LogToFile("[RC] STUCK at PC=0x%llx (last 20 iters no change)", (unsigned long long)pcM);
            break;
        }
    }

    return result;
}

extern "C" void ProbeRemote() {
    remove(kLogPath);
    LogToFile("========== REMOTE CALL TEST 4 ==========");

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

    // ─── TEST 1 ────────────────────────────────────────────────
    LogToFile("[TEST1] our own add function");
    int krAlloc = 0;
    uint64_t codePage = VMAlloc(gTask, 0x1000, &krAlloc);
    LogToFile("[TEST1] codePage = 0x%llx (kr=%d)", (unsigned long long)codePage, krAlloc);

    // add x0, x0, x1 ; ret
    uint32_t addFunc[2] = { 0x8B010000, 0xD65F03C0 };
    bool wr = VMWrite(gTask, codePage, addFunc, 8);
    LogToFile("[TEST1] write = %s", wr ? "OK" : "FAIL");

    uint32_t verify[2] = {0};
    VMRead(gTask, codePage, verify, 8);
    LogToFile("[TEST1] verify: %08x %08x (expected 8b010000 d65f03c0)",
              verify[0], verify[1]);

    uint64_t r1 = RemoteCall2(gTask, codePage, 5, 7);
    LogToFile("[TEST1] add(5, 7) = %llu (expect 12)", (unsigned long long)r1);

    // ─── TEST 2 ────────────────────────────────────────────────
    LogToFile("[TEST2] GetHp(localPlayer)");
    uint64_t matchGame = getMatchGame(Moudule_Base);
    LogToFile("Moudule_Base = 0x%llx", (unsigned long long)Moudule_Base);
    LogToFile("matchGame = 0x%llx", (unsigned long long)matchGame);

    if (matchGame) {
        uint64_t match = getMatch(matchGame);
        LogToFile("match = 0x%llx", (unsigned long long)match);
        if (match) {
            uint64_t local = getLocalPlayer(match);
            LogToFile("local = 0x%llx", (unsigned long long)local);
            if (local) {
                int hpDirect = get_CurHP(local);
                int hpMax    = get_MaxHP(local);
                LogToFile("direct HP = %d / %d", hpDirect, hpMax);

                uint64_t getHpAddr = gUnityBase + 0x543592C;
                LogToFile("GetHp addr = 0x%llx", (unsigned long long)getHpAddr);

                uint64_t r2 = RemoteCall2(gTask, getHpAddr, local, 0);
                LogToFile("[TEST2] remote GetHp = %lld", (long long)r2);
                if ((int)r2 == hpDirect)
                    LogToFile("[TEST2] *** MATCH ***");
                else
                    LogToFile("[TEST2] mismatch direct=%d remote=%lld", hpDirect, (long long)r2);
            }
        }
    } else {
        LogToFile("no matchGame");
    }

    LogToFile("========== DONE ==========");
}
