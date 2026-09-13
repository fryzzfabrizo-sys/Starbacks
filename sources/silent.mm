// silent.mm
// Дамп структуры HitCollider с float-интерпретацией

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>
#include <cstdio>
#include <cstring>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_HitCollider    = 0x20;
static constexpr uint64_t kHit_ActorLayer     = 0x60;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;
static uint64_t          g_lastDumpCollider = 0;

static void LogToFile(const char* fmt, ...) {
    FILE* f = fopen("/var/mobile/Documents/collider_dump.log", "a");
    if (!f) return;
    va_list args; va_start(args, fmt);
    vfprintf(f, fmt, args); va_end(args);
    fputc('\n', f); fclose(f);
}

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};
    uint64_t node = ReadAddr<uint64_t>(pawn + kBodyPart_TransNode);
    if (!validPtr(node)) return {};
    return getPositionExt(node);
}

// Красивый дамп структуры с float-интерпретацией
static void DumpStruct(const char* tag, uint64_t addr) {
    if (!validPtr(addr)) return;

    LogToFile("========= %s  0x%llx =========", tag,
              (unsigned long long)addr);

    for (int row = 0; row < 8; row++) {
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

        LogToFile("+%02llx:  %08x %08x %08x %08x",
                  (unsigned long long)off, v0, v1, v2, v3);
        LogToFile("       f:  %10.4f %10.4f %10.4f %10.4f",
                  f0, f1, f2, f3);
    }
    LogToFile("");
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
        }
        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(h + kHit_RayDir, diff);

        // Дамп при изменении коллайдера
        uint64_t col = ReadAddr<uint64_t>(h + kHit_HitCollider);
        int32_t  lay = ReadAddr<int32_t>(h + kHit_ActorLayer);

        if (validPtr(col) && col != g_lastDumpCollider) {
            g_lastDumpCollider = col;

            char tag[64];
            snprintf(tag, sizeof(tag), "COLLIDER layer=%d", lay);
            DumpStruct(tag, col);

            // Если есть указатели на +0x10, +0x20 — раскрутить их тоже
            uint64_t p10 = ReadAddr<uint64_t>(col + 0x10);
            uint64_t p20 = ReadAddr<uint64_t>(col + 0x20);

            if (validPtr(p10))
                DumpStruct("  +0x10 deref", p10);
            if (validPtr(p20))
                DumpStruct("  +0x20 deref", p20);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(80));
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
    g_tPos   = {};
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
        g_lastMatch = 0;
        ResetSilentAim();
        return;
    }
    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!validPtr(local) || !validPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (!validVec(tPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
    }
    g_hasData.store(true, std::memory_order_release);

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };
    WriteAddr<Vector3>(aimPtr + kHit_RayDir, diff);
}
