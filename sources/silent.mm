#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t Moudule_Base;
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

static uint64_t g_aimPtr   = 0;
static uint64_t g_aimKlass = 0;
static uint64_t g_target   = 0;
static uint64_t g_local    = 0;
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
//  WORKER — свежие head + origin каждый тик
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::microseconds(500));
            continue;
        }

        uint64_t h, target, local, expectedKlass;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h             = g_aimPtr;
            target        = g_target;
            local         = g_local;
            expectedKlass = g_aimKlass;
        }
        if (!validPtr(h) || !isVaildPtr(target)) {
            std::this_thread::yield();
            continue;
        }

        // Защита от краша: klass pointer
        uint64_t curKlass = ReadAddr<uint64_t>(h + 0);
        if (curKlass != expectedKlass) {
            std::this_thread::yield();
            continue;
        }

        // Свежая позиция головы
        Vector3 head = HeadPos(target);
        if (isZeroV3(head)) { std::this_thread::yield(); continue; }
        head.y += kHeadCenterY;

        // Свежий origin
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = HeadPos(local);

        // Направление
        Vector3 dir = { head.x - origin.x, head.y - origin.y, head.z - origin.z };
        WriteAddr<Vector3>(h + kHit_RayDir, dir);

        std::this_thread::yield();
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
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = 0;
        g_aimKlass = 0;
        g_target   = 0;
        g_local    = 0;
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — только указатели, никакой математики
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
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

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t klass = ReadAddr<uint64_t>(aimPtr + 0);
    if (!validPtr(klass)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = aimPtr;
        g_aimKlass = klass;
        g_target   = target;
        g_local    = local;
    }
    g_hasData.store(true, std::memory_order_release);
}
