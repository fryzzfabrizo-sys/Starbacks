#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

static constexpr float kHeadCenterY = 0.055f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr = 0;
static Vector3           g_tPos   = {};
static Vector3           g_lPos   = {};

static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  WORKER — твой рабочий вариант (без klass check, с нормализацией)
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t h;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            lPos = g_lPos;
        }
        if (!validPtr(h)) continue;

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
        float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastMatch = 0;
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // ═══ ФИКС СМЕНЫ МАТЧА ═══
    // Отслеживаем по cachedMatch (надёжнее чем local).
    // При смене сбрасываем aimPtr и пропускаем кадр.
    if (cachedMatch != g_lastMatch) {
        g_lastMatch = cachedMatch;
        g_hasData.store(false, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lk(g_lock);
            g_aimPtr = 0;
        }
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (isZeroV3(tPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }
    // Центр черепа вместо основания
    tPos.y += kHeadCenterY;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_lPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}
