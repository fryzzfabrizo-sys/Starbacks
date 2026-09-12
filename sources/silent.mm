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
static constexpr uint64_t kHit_Scatter        = 0x5C;

// ═══ Проверка "стреляем ли" ═══
static constexpr uint64_t kIsFiring           = 0x770;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_localPlayer    = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  WORKER — читает aimPtr СВЕЖИМ, пишет при выстреле
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t local;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local = g_localPlayer;
            tPos  = g_tPos;
            lPos  = g_lPos;
            vel   = g_targetVelocity;
        }
        if (!isVaildPtr(local)) {
            std::this_thread::yield();
            continue;
        }

        // ═══ СВЕЖИЙ aimPtr — перечитываем КАЖДЫЙ тик ═══
        uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
        if (!validPtr(aimPtr)) {
            std::this_thread::yield();
            continue;
        }

        // Предсказание
        Vector3 predPos = {
            tPos.x + vel.x * 0.06f,
            tPos.y + vel.y * 0.06f,
            tPos.z + vel.z * 0.06f
        };

        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { predPos.x - origin.x, predPos.y - origin.y, predPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        // ═══ Пишем dir НЕСКОЛЬКО раз подряд ═══
        // Для одиночных оружий — попадает в окно между выстрелами
        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
        WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);

        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
        WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);

        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
        WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);
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

    if (get_CurHP(target) <= 0) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    // Скорость цели
    if (g_prevTargetPos.x != 0.0f || g_prevTargetPos.y != 0.0f || g_prevTargetPos.z != 0.0f) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float distSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        if (distSq < 25.0f) {
            g_targetVelocity = delta;
        } else {
            g_targetVelocity = {0.0f, 0.0f, 0.0f};
        }
    } else {
        g_targetVelocity = {0.0f, 0.0f, 0.0f};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_localPlayer = local;
        g_tPos        = tPos;
        g_lPos        = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}
