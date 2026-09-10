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

// ═══════════════════════════════════════════════════════════════
//  ПАРАМЕТРЫ ПРЕДСКАЗАНИЯ
// ═══════════════════════════════════════════════════════════════
static constexpr float kLeadSec        = 0.045f;  // горизонталь
static constexpr float kLeadSecVert    = 0.085f;  // вертикаль (прыжок/присед — быстрее)
static constexpr float kVelSmoothXZ    = 0.55f;   // EMA X/Z
static constexpr float kVelSmoothY     = 0.85f;   // EMA Y — реакция почти мгновенная
static constexpr float kMaxVel         = 25.0f;
static constexpr float kHeadTopBias    = 0.055f;  // смещение к верхней части черепа
static constexpr float kAirborneExtra  = 0.030f;  // доп. лид в воздухе по Y
static constexpr float kCrouchExtra    = 0.020f;  // доп. лид при приседе по Y

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t g_aimPtr = 0;
static Vector3  g_tPos   = {};
static Vector3  g_tVel   = {};
static Vector3  g_lPos   = {};
static Vector3  g_lVel   = {};
static float    g_tExtraY = 0.0f;   // динамический вертикальный бонус

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
//  WORKER — считает направление с полным предсказанием
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3 tPos, tVel, lPos, lVel;
        float   extraY;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h      = g_aimPtr;
            tPos   = g_tPos;
            tVel   = g_tVel;
            lPos   = g_lPos;
            lVel   = g_lVel;
            extraY = g_tExtraY;
        }
        if (!validPtr(h)) continue;

        // ─── Предсказание позиции головы цели ──────────────
        Vector3 predTarget = {
            tPos.x + tVel.x * kLeadSec,
            tPos.y + tVel.y * kLeadSecVert + kHeadTopBias + extraY,
            tPos.z + tVel.z * kLeadSec
        };

        // ─── Origin пули: свежий из памяти игры ────────────
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) {
            origin = {
                lPos.x + lVel.x * kLeadSec * 0.5f,
                lPos.y + lVel.y * kLeadSec * 0.5f,
                lPos.z + lVel.z * kLeadSec * 0.5f
            };
        } else {
            // Компенсация движения стрелка в момент прилёта
            origin.x += lVel.x * kLeadSec * 0.6f;
            origin.y += lVel.y * kLeadSec * 0.6f;
            origin.z += lVel.z * kLeadSec * 0.6f;
        }

        Vector3 diff = {
            predTarget.x - origin.x,
            predTarget.y - origin.y,
            predTarget.z - origin.z
        };
        float lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

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
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        g_tVel = {}; g_lVel = {};
        g_tExtraY = 0.0f;
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — обновляет данные для воркера
// ═══════════════════════════════════════════════════════════════
static Vector3 s_prevTargetPos = {};
static Vector3 s_prevLocalPos  = {};
static float   s_prevTargetY   = 0.0f;
static bool    s_havePrevTarget = false;
static bool    s_havePrevLocal  = false;
static std::chrono::steady_clock::time_point s_prevTick;

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        g_lastMatch = 0;
        ResetSilentAim();
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        return;
    }

    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        s_prevTick = std::chrono::steady_clock::now();
        return;
    }

    auto now = std::chrono::steady_clock::now();
    float dt = std::chrono::duration<float>(now - s_prevTick).count();
    s_prevTick = now;
    if (dt <= 0.001f || dt > 0.25f) dt = 0.016f;

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        return;
    }

    Vector3 tPos = HeadPos(target);
    Vector3 lPos = HeadPos(local);
    if (isZeroV3(tPos) || isZeroV3(lPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // ─── Скорость цели ────────────────────────────────────
    Vector3 newTVel = {0, 0, 0};
    if (s_havePrevTarget) {
        newTVel = {
            (tPos.x - s_prevTargetPos.x) / dt,
            (tPos.y - s_prevTargetPos.y) / dt,
            (tPos.z - s_prevTargetPos.z) / dt
        };
        float len = std::sqrt(newTVel.x*newTVel.x + newTVel.y*newTVel.y + newTVel.z*newTVel.z);
        if (len > kMaxVel) {
            float k = kMaxVel / len;
            newTVel.x *= k; newTVel.y *= k; newTVel.z *= k;
        }
    }
    s_prevTargetPos = tPos;
    s_havePrevTarget = true;

    // ─── Скорость локального игрока ───────────────────────
    Vector3 newLVel = {0, 0, 0};
    if (s_havePrevLocal) {
        newLVel = {
            (lPos.x - s_prevLocalPos.x) / dt,
            (lPos.y - s_prevLocalPos.y) / dt,
            (lPos.z - s_prevLocalPos.z) / dt
        };
        float len = std::sqrt(newLVel.x*newLVel.x + newLVel.y*newLVel.y + newLVel.z*newLVel.z);
        if (len > kMaxVel) {
            float k = kMaxVel / len;
            newLVel.x *= k; newLVel.y *= k; newLVel.z *= k;
        }
    }
    s_prevLocalPos = lPos;
    s_havePrevLocal = true;

    // ─── Детект прыжка/приседа цели по голове ─────────────
    // Если голова резко поднялась (>+0.4 u/s) — прыжок,
    // если резко опустилась (<-0.4 u/s) — присед.
    float extraY = 0.0f;
    if (s_havePrevTarget) {
        if (newTVel.y >  0.4f) extraY += kAirborneExtra;
        if (newTVel.y < -0.4f) extraY += kCrouchExtra;
    }
    // Разница высот между тобой и целью (стрельба снизу/сверху)
    float heightDiff = tPos.y - lPos.y;
    if (heightDiff > 1.5f)  extraY += 0.020f; // враг сильно выше
    if (heightDiff < -1.5f) extraY += 0.015f; // ты сильно ниже — целься выше

    {
        std::lock_guard<std::mutex> lk(g_lock);

        // X и Z — обычное сглаживание
        g_tVel.x = g_tVel.x * (1.0f - kVelSmoothXZ) + newTVel.x * kVelSmoothXZ;
        g_tVel.z = g_tVel.z * (1.0f - kVelSmoothXZ) + newTVel.z * kVelSmoothXZ;
        // Y — почти без сглаживания (реакция на прыжок/присед)
        g_tVel.y = g_tVel.y * (1.0f - kVelSmoothY) + newTVel.y * kVelSmoothY;

        g_lVel.x = g_lVel.x * (1.0f - kVelSmoothXZ) + newLVel.x * kVelSmoothXZ;
        g_lVel.y = g_lVel.y * (1.0f - kVelSmoothY)  + newLVel.y * kVelSmoothY;
        g_lVel.z = g_lVel.z * (1.0f - kVelSmoothXZ) + newLVel.z * kVelSmoothXZ;

        g_tPos = tPos;
        g_lPos = lPos;
        g_tExtraY = extraY;
        g_aimPtr = aimPtr;
    }
    g_hasData.store(true, std::memory_order_release);

    // ─── Мгновенный пинг (первый выстрел тоже ловит свежак) ─
    Vector3 predTarget = {
        g_tPos.x + g_tVel.x * kLeadSec,
        g_tPos.y + g_tVel.y * kLeadSecVert + kHeadTopBias + extraY,
        g_tPos.z + g_tVel.z * kLeadSec
    };
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    if (isZeroV3(origin)) origin = g_lPos;
    Vector3 diff = {
        predTarget.x - origin.x,
        predTarget.y - origin.y,
        predTarget.z - origin.z
    };
    float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
    if (lenSq > 0.0001f) {
        float inv = 1.0f / std::sqrt(lenSq);
        WriteAddr<Vector3>(aimPtr + kHit_RayDir,
                           Vector3{diff.x*inv, diff.y*inv, diff.z*inv});
    }
}
