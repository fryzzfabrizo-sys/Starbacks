// silent.mm
// Silent aim + запись HitCollider для попаданий через стены

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Offsets ────────────────────────────────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

// HitInfo offsets
static constexpr uint64_t kHit_GameObject     = 0x18;
static constexpr uint64_t kHit_HeadCollider   = 0x20;
static constexpr uint64_t kHit_HitLoc         = 0x28;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

// Пути к коллайдеру цели на Player
static constexpr uint64_t kPlayer_AimCollider = 0x6C8;   // AimCollider_Ptr
static constexpr uint64_t kPlayer_LockAimCol  = 0x140;   // LockAimCollider_Backing

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_collider  = 0;
static uint64_t          g_lastMatch = 0;

// ─── Helpers ────────────────────────────────────────────────────────
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
    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};
    return getPositionExt(node);
}

// Достаём head collider цели (пробуем оба оффсета)
static uint64_t TargetCollider(uint64_t pawn) {
    if (!validPtr(pawn)) return 0;

    uint64_t c = ReadAddr<uint64_t>(pawn + kPlayer_AimCollider);
    if (validPtr(c)) return c;

    c = ReadAddr<uint64_t>(pawn + kPlayer_LockAimCol);
    if (validPtr(c)) return c;

    return 0;
}

// ─── Worker ─────────────────────────────────────────────────────────
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h, col;
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            col  = g_collider;
        }

        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };

        // 1. RayDir — основное (для видимых)
        WriteAddr<Vector3>(h + kHit_RayDir, diff);

        // 2. HitLocation — куда попали (world)
        WriteAddr<Vector3>(h + kHit_HitLoc, tPos);

        // 3. HitCollider — прямая ссылка на коллайдер цели (для стен)
        if (validPtr(col)) {
            WriteAddr<uint64_t>(h + kHit_HeadCollider, col);
        }
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
    g_tPos     = {};
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

    Vector3 tPos = HeadPos(target);
    if (!validVec(tPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t collider = TargetCollider(target);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = aimPtr;
        g_tPos     = tPos;
        g_collider = collider;
    }
    g_hasData.store(true, std::memory_order_release);

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };

    WriteAddr<Vector3>(aimPtr + kHit_RayDir, diff);
    WriteAddr<Vector3>(aimPtr + kHit_HitLoc, tPos);
    if (validPtr(collider)) {
        WriteAddr<uint64_t>(aimPtr + kHit_HeadCollider, collider);
    }
}
