// SilentAim.mm
// Silent aim — чистая запись Hit_HeadCollider (0x20). Без фолбэков.

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Player field offsets ───────────────────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;   // Player_HitObjectInfoWp
static constexpr uint64_t kPlayer_HeadNode    = 0x638;   // Player_HeadTF
static constexpr uint64_t kPlayer_AimCollider = 0x6C8;   // kAimCollider_Ptr
static constexpr uint64_t kPlayer_LockAimCol  = 0x140;   // kLockAimCollider
static constexpr uint64_t kBodyPart_TransNode = 0x10;

// ─── HitInfo (GMPGMPFNMFP) ──────────────────────────────────────────
static constexpr uint64_t kHit_HeadCollider   = 0x20;

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static uint64_t          g_target    = 0;
static uint64_t          g_collider  = 0;
static uint64_t          g_lastMatch = 0;

// ─── Helpers ────────────────────────────────────────────────────────
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

// Достаём указатель на head collider цели
static uint64_t TargetHeadCollider(uint64_t target) {
    if (!validPtr(target)) return 0;

    uint64_t c = ReadAddr<uint64_t>(target + kPlayer_AimCollider);
    if (validPtr(c)) return c;

    c = ReadAddr<uint64_t>(target + kPlayer_LockAimCol);
    if (validPtr(c)) return c;

    return 0;
}

// ─── Silent Worker ──────────────────────────────────────────────────
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h, col;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h   = g_aimPtr;
            col = g_collider;
        }

        if (!validPtr(h) || !validPtr(col)) {
            std::this_thread::yield();
            continue;
        }

        WriteAddr<uint64_t>(h + kHit_HeadCollider, col);
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
    g_aimPtr   = 0;
    g_target   = 0;
    g_collider = 0;
}

// ─── Main ───────────────────────────────────────────────────────────
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

    uint64_t collider = TargetHeadCollider(target);
    if (!validPtr(collider)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = aimPtr;
        g_target   = target;
        g_collider = collider;
    }
    g_hasData.store(true, std::memory_order_release);

    // мгновенная запись в кадре
    WriteAddr<uint64_t>(aimPtr + kHit_HeadCollider, collider);
}
