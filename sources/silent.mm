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

// ═══════════════════════════════════════════════════════════════
//  FAST FIRE — параметры
// ═══════════════════════════════════════════════════════════════
#define FAST_FIRE 1           // 0 = выключить полностью
#define INF_AMMO  1           // 0 = патроны тратятся как обычно

static constexpr float kFireInterval = 0.01f;   // 10 мс между выстрелами (мин. быстрота)

// ═══════════════════════════════════════════════════════════════
//  Silent Aim offsets
// ═══════════════════════════════════════════════════════════════
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_Scatter        = 0x5C;

// ═══════════════════════════════════════════════════════════════
//  Weapon offsets (из твоих offsets)
// ═══════════════════════════════════════════════════════════════
static constexpr uint64_t kFastFireOff   = 0x208;   // float — интервал между выстрелами
static constexpr uint64_t kWeaponCostAmmo = 0x7B8;  // bool — тратит ли патроны

// ═══════════════════════════════════════════════════════════════
//  State
// ═══════════════════════════════════════════════════════════════
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t          g_aimPtr         = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_localPlayer    = 0;
static uint64_t          g_lastMatch      = 0;

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
//  FAST FIRE + INF AMMO
//  Вызывается из Worker'а каждый тик
// ═══════════════════════════════════════════════════════════════
static void ApplyFastFire(uint64_t local) {
#if FAST_FIRE || INF_AMMO
    if (!isVaildPtr(local)) return;

    uint64_t wpn = WeaponOnHand(local);
    if (!isVaildPtr(wpn)) return;

#if FAST_FIRE
    // Обнуляем интервал между выстрелами
    // Игра читает это как float-таймер, минимум = почти мгновенно
    WriteAddr<float>(wpn + kFastFireOff, kFireInterval);
#endif

#if INF_AMMO
    // m_CostAmmo = false — патроны не тратятся при выстреле
    WriteAddr<bool>(wpn + kWeaponCostAmmo, false);
#endif

#endif
}

// ═══════════════════════════════════════════════════════════════
//  WORKER
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h, local;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h     = g_aimPtr;
            local = g_localPlayer;
            tPos  = g_tPos;
            lPos  = g_lPos;
            vel   = g_targetVelocity;
        }
        if (!validPtr(h)) continue;

        // ═══ FAST FIRE + INF AMMO ═══
        ApplyFastFire(local);

        // ═══ SILENT AIM ═══
        Vector3 predPos = {
            tPos.x + vel.x * 0.06f,
            tPos.y + vel.y * 0.06f,
            tPos.z + vel.z * 0.06f
        };

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        Vector3 diff  = { predPos.x - origin.x, predPos.y - origin.y, predPos.z - origin.z };
        float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
        WriteAddr<float>(h + kHit_Scatter, 0.0f);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastMatch      = 0;
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    g_localPlayer    = 0;
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
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

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
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

    // Скорость цели
    if (!isZeroV3(g_prevTargetPos)) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float dSq = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
        g_targetVelocity = (dSq < 25.0f) ? delta : Vector3{0,0,0};
    } else {
        g_targetVelocity = {0,0,0};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr      = aimPtr;
        g_localPlayer = local;
        g_tPos        = tPos;
        g_lPos        = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);

    // ═══ FAST FIRE — пинг для мгновенного применения ═══
    ApplyFastFire(local);

    // Мгновенный пинг silent aim
    if (validPtr(aimPtr)) {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (isZeroV3(origin)) origin = g_lPos;

        Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
        float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq > 0.0001f) {
            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };
            WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
            WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);
        }
    }
}
