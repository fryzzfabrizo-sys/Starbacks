// SilentAim.mm
// Silent aim по принципу AimSilentThread: guard по IsFiring, запись RayDir (0x40) + TargetPos (0x28)

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Offsets ────────────────────────────────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;   // HitObjectInfo
static constexpr uint64_t kHit_RayDir         = 0x40;    // Vector3 RayDir
static constexpr uint64_t kHit_StartPos       = 0x4C;    // Vector3 ammo base
static constexpr uint64_t kHit_TargetPos      = 0x28;    // Vector3 TargetPos

static constexpr uint64_t kPlayer_HeadNode    = 0x638;   // ITransformNode Head
static constexpr uint64_t kBodyPart_TransNode = 0x10;    // ITransformNode -> Transform

// ─── Shared state ───────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

// ─── Helpers ────────────────────────────────────────────────────────
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}

// Голова по оффсету: Player + 0x638 -> BodyPart + 0x10 -> Transform -> getPositionExt
static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};

    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};

    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};

    return getPositionExt(node);
}

// ─── Background thread ─────────────────────────────────────────────
static void AimSilentThread() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));

        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t h;
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
        }

        if (!validPtr(h) || !validVec(tPos)) continue;

        // Текущий origin (ammo base)
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);

        // direction = target - origin
        Vector3 dir = { tPos.x - origin.x,
                        tPos.y - origin.y,
                        tPos.z - origin.z };

        // Запись: direction в 0x40, target в 0x28
        WriteAddr<Vector3>(h + kHit_RayDir,    dir);
        WriteAddr<Vector3>(h + kHit_TargetPos, tPos);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(AimSilentThread).detach();
}

static inline void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
    g_tPos   = {};
}

// ─── Main (каждый кадр) ────────────────────────────────────────────
void RunSilentAim() {
    // Фича выключена → flush
    if (!aimsilent1) {
        if (g_hasData.load(std::memory_order_acquire)) ResetSilentAim();
        return;
    }

    if (IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
        g_lastMatch = 0;
        if (g_hasData.load(std::memory_order_acquire)) ResetSilentAim();
        return;
    }

    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        return;
    }

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!validPtr(local)) {
        if (g_hasData.load(std::memory_order_acquire)) ResetSilentAim();
        return;
    }

    // Guard по стрельбе — как в AimSilentThread
    if (!get_IsFiring(local)) {
        if (g_hasData.load(std::memory_order_acquire)) ResetSilentAim();
        return;
    }

    uint64_t target = g_SilentBestTarget;
    if (!validPtr(target)) {
        if (g_hasData.load(std::memory_order_acquire)) ResetSilentAim();
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        if (g_hasData.load(std::memory_order_acquire)) ResetSilentAim();
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (!validVec(tPos)) {
        if (g_hasData.load(std::memory_order_acquire)) ResetSilentAim();
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенная запись в кадре (не ждём thread)
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 dir    = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };

    WriteAddr<Vector3>(aimPtr + kHit_RayDir,    dir);
    WriteAddr<Vector3>(aimPtr + kHit_TargetPos, tPos);
}
