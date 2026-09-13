// capsule_probe.mm
// Диагностика CapsuleCollider игрока (Player + 0xAB0)
// Лог: /var/mobile/Documents/capsule_dump.log

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <chrono>

extern uint64_t cachedMatch;
extern uint64_t g_SilentBestTarget;

static constexpr uint64_t kPlayer_CapsuleCollider = 0xAB0;  // Player + 0xAB0
static constexpr uint64_t kManaged_CachedPtr      = 0x10;   // managed -> native

static const char* kLogPath = "/var/mobile/Documents/capsule_dump.log";

static void LogLine(const char* fmt, ...) {
    FILE* f = fopen(kLogPath, "a");
    if (!f) return;
    va_list args; va_start(args, fmt);
    vfprintf(f, fmt, args); va_end(args);
    fputc('\n', f); fclose(f);
}

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static void DumpNative(uint64_t addr, const char* tag) {
    LogToFile:;
    LogLine("========= %s  addr=0x%llx =========",
            tag, (unsigned long long)addr);

    for (int row = 0; row < 16; row++) {   // 256 байт
        uint64_t off = row * 16;
        uint32_t v0 = ReadAddr<uint32_t>(addr + off + 0);
        uint32_t v1 = ReadAddr<uint32_t>(addr + off + 4);
        uint32_t v2 = ReadAddr<uint32_t>(addr + off + 8);
        uint32_t v3 = ReadAddr<uint32_t>(addr + off + 12);
        float f0, f1, f2, f3;
        memcpy(&f0, &v0, 4);
        memcpy(&f1, &v1, 4);
        memcpy(&f2, &v2, 4);
        memcpy(&f3, &v3, 4);
        LogLine("+%03llx:  %08x %08x %08x %08x    f: %8.4f %8.4f %8.4f %8.4f",
                (unsigned long long)off, v0, v1, v2, v3, f0, f1, f2, f3);
    }
    LogLine("");
}

extern "C" void ProbeCapsule() {
    remove(kLogPath);
    LogLine("========== CAPSULE PROBE ==========");

    if (!validPtr(cachedMatch)) { LogLine("no match"); return; }
    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!validPtr(local))  { LogLine("no local"); return; }
    if (!validPtr(target)) { LogLine("no target"); return; }

    LogLine("local  = 0x%llx", (unsigned long long)local);
    LogLine("target = 0x%llx", (unsigned long long)target);

    // Сначала дамп с ЛОКАЛЬНОГО игрока (у нас всегда есть)
    uint64_t managedCol = ReadAddr<uint64_t>(local + kPlayer_CapsuleCollider);
    LogLine("local  + 0xAB0 (managed CapsuleCollider) = 0x%llx",
            (unsigned long long)managedCol);

    if (!validPtr(managedCol)) {
        LogLine("managed collider invalid");
        return;
    }
    DumpNative(managedCol, "MANAGED CapsuleCollider");

    uint64_t nativeCol = ReadAddr<uint64_t>(managedCol + kManaged_CachedPtr);
    LogLine("managed + 0x10 (m_CachedPtr -> native) = 0x%llx",
            (unsigned long long)nativeCol);

    if (validPtr(nativeCol)) {
        DumpNative(nativeCol, "NATIVE CapsuleCollider");
    }

    // Также с цели, если она есть
    if (validPtr(target)) {
        uint64_t tm = ReadAddr<uint64_t>(target + kPlayer_CapsuleCollider);
        LogLine("target + 0xAB0 = 0x%llx", (unsigned long long)tm);
        if (validPtr(tm)) {
            DumpNative(tm, "TARGET MANAGED CapsuleCollider");
            uint64_t tn = ReadAddr<uint64_t>(tm + kManaged_CachedPtr);
            if (validPtr(tn)) DumpNative(tn, "TARGET NATIVE CapsuleCollider");
        }
    }

    LogLine("========== DONE ==========");
    LogLine("");
}
