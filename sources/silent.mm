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
//  ПАРАМЕТРЫ (калибровано по bind-pose bone_Head из T-pose)
//  bind-pose Neck→Head = 0.0448 (male) / 0.0390 (female)
//  + радиус черепа сверху = центр головы
// ═══════════════════════════════════════════════════════════════

// ── Предсказание движения ─────────────────────────────────
static constexpr float kLeadBase      = 0.035f;
static constexpr float kLeadPerMeter  = 0.0006f;
static constexpr float kLeadVertMult  = 1.10f;
static constexpr float kLeadMax       = 0.070f;

// ── Сглаживание (XZ плавно, Y почти мгновенно) ────────────
static constexpr float kSmoothXZ      = 0.60f;
static constexpr float kSmoothY       = 0.85f;
static constexpr float kMaxVel        = 25.0f;

// ── Захват головы (по данным bind-pose из JSON) ──────────
static constexpr float kHeadCenterY   = 0.090f;   // Neck→Head + радиус черепа
static constexpr float kAirborneExtra = 0.020f;   // доп. лифт в прыжке врага
static constexpr float kCrouchExtra   = 0.012f;   // доп. лифт при приседе
static constexpr float kBelowBias     = 0.015f;   // стрельба снизу вверх

// ── Границы ───────────────────────────────────────────────
static constexpr float kMinDistance   = 0.5f;
static constexpr float kMinLenSq      = 0.0001f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t g_aimPtr = 0;
static Vector3  g_tPos   = {};
static Vector3  g_tVel   = {};
static Vector3  g_lPos   = {};
static Vector3  g_lVel   = {};
static float    g_extraY = 0.0f;

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
//  WORKER — постоянно пишет направление, выигрывая гонку с игрой
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
            extraY = g_extraY;
        }
        if (!validPtr(h)) continue;

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        float dxT = tPos.x - origin.x;
        float dyT = tPos.y - origin.y;
        float dzT = tPos.z - origin.z;
        float dist = std::sqrt(dxT*dxT + dyT*dyT + dzT*dzT);
        if (dist < kMinDistance) continue;

        float leadTotal = kLeadBase + kLeadPerMeter * dist;
        if (leadTotal > kLeadMax) leadTotal = kLeadMax;
        float leadVert  = leadTotal * kLeadVertMult;

        Vector3 pred = {
            tPos.x + tVel.x * leadTotal,
            tPos.y + tVel.y * leadVert + kHeadCenterY + extraY,
            tPos.z + tVel.z * leadTotal
        };

        origin.x += lVel.x * leadTotal * 0.6f;
        origin.y += lVel.y * leadTotal * 0.6f;
        origin.z += lVel.z * leadTotal * 0.6f;

        Vector3 diff = { pred.x - origin.x, pred.y - origin.y, pred.z - origin.z };
        float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq <= kMinLenSq) continue;

        float inv = 1.0f / std::sqrt(lenSq);
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
        g_extraY = 0.0f;
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — считает скорости цели и стрелка
// ═══════════════════════════════════════════════════════════════
static Vector3 s_prevTargetPos = {};
static Vector3 s_prevLocalPos  = {};
static bool    s_havePrevTarget = false;
static bool    s_havePrevLocal  = false;
static std::chrono::steady_clock::time_point s_prevTick;

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
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

    // ─── Скорость цели ──────────────────────────────────
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

    // ─── Скорость стрелка ───────────────────────────────
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

    // ─── Контекстные бонусы (прыжок/присед/высота) ─────
    float extraY = 0.0f;
    if (s_havePrevTarget) {
        if (newTVel.y >  0.4f) extraY += kAirborneExtra;
        if (newTVel.y < -0.4f) extraY += kCrouchExtra;
    }
    float heightDiff = tPos.y - lPos.y;
    if (heightDiff < -1.5f) extraY += kBelowBias;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_tVel.x = g_tVel.x * (1.0f - kSmoothXZ) + newTVel.x * kSmoothXZ;
        g_tVel.z = g_tVel.z * (1.0f - kSmoothXZ) + newTVel.z * kSmoothXZ;
        g_tVel.y = g_tVel.y * (1.0f - kSmoothY)  + newTVel.y * kSmoothY;

        g_lVel.x = g_lVel.x * (1.0f - kSmoothXZ) + newLVel.x * kSmoothXZ;
        g_lVel.y = g_lVel.y * (1.0f - kSmoothY)  + newLVel.y * kSmoothY;
        g_lVel.z = g_lVel.z * (1.0f - kSmoothXZ) + newLVel.z * kSmoothXZ;

        g_tPos   = tPos;
        g_lPos   = lPos;
        g_extraY = extraY;
        g_aimPtr = aimPtr;
    }
    g_hasData.store(true, std::memory_order_release);

    // ─── Мгновенный пинг (первый выстрел ловит свежие данные) ─
    {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        float dxT = tPos.x - origin.x;
        float dyT = tPos.y - origin.y;
        float dzT = tPos.z - origin.z;
        float dist = std::sqrt(dxT*dxT + dyT*dyT + dzT*dzT);
        if (dist > kMinDistance) {
            float leadTotal = kLeadBase + kLeadPerMeter * dist;
            if (leadTotal > kLeadMax) leadTotal = kLeadMax;
            float leadVert  = leadTotal * kLeadVertMult;

            Vector3 pred = {
                tPos.x + g_tVel.x * leadTotal,
                tPos.y + g_tVel.y * leadVert + kHeadCenterY + extraY,
                tPos.z + g_tVel.z * leadTotal
            };
            origin.x += g_lVel.x * leadTotal * 0.6f;
            origin.y += g_lVel.y * leadTotal * 0.6f;
            origin.z += g_lVel.z * leadTotal * 0.6f;

            Vector3 diff = { pred.x - origin.x, pred.y - origin.y, pred.z - origin.z };
            float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
            if (lenSq > kMinLenSq) {
                float inv = 1.0f / std::sqrt(lenSq);
                Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };
                WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
            }
        }
    }
}
