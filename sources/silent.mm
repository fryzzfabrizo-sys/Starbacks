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
//  ФИЗИКА
// ═══════════════════════════════════════════════════════════════
static constexpr float kBulletSpeed    = 350.0f;
static constexpr float kServerLag      = 0.030f;
static constexpr float kLeadMin        = 0.020f;
static constexpr float kLeadMax        = 0.100f;

static constexpr float kGravity        = 18.0f;

static constexpr float kSmoothVelXZ    = 0.65f;
static constexpr float kSmoothVelY     = 0.85f;
static constexpr float kSmoothVelYAir  = 0.98f;
static constexpr float kSmoothAccelXZ  = 0.30f;
static constexpr float kSmoothAccelY   = 0.55f;
static constexpr float kSmoothLocalVel = 0.75f;   // сглаживание своей скорости

static constexpr float kMaxVel         = 30.0f;
static constexpr float kMaxAccel       = 60.0f;

static constexpr float kJumpVelThresh  = 0.6f;
static constexpr float kJumpAccelThresh = 4.0f;

static constexpr float kHeadCenterY    = 0.090f;
static constexpr float kAirborneExtraY = 0.015f;
static constexpr float kCrouchExtraY   = 0.010f;
static constexpr float kBelowBiasY     = 0.015f;

// ── Компенсация задержки выстрела ────────────────────────
// Игра применяет нашу dir через N кадров после записи.
// 1 кадр ≈ 0.016s. Значение = доля компенсации 0.0..1.0
static constexpr float kLocalLeadFactor = 0.65f;

static constexpr float kMinDistance    = 0.5f;
static constexpr float kMinLenSq       = 0.0001f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t g_aimPtr = 0;
static Vector3  g_tPos   = {};
static Vector3  g_tVel   = {};
static Vector3  g_tAccel = {};
static Vector3  g_lPos   = {};
static Vector3  g_lVel   = {};
static float    g_extraY = 0.0f;
static bool     g_tAirborne = false;

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
//  WORKER
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3 tPos, tVel, tAcc, lPos, lVel;
        float   extraY;
        bool    airborne;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            tPos     = g_tPos;
            tVel     = g_tVel;
            tAcc     = g_tAccel;
            lPos     = g_lPos;
            lVel     = g_lVel;
            extraY   = g_extraY;
            airborne = g_tAirborne;
        }
        if (!validPtr(h)) continue;

        // ── Origin как есть ─────────────────────────────
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        // ── Дистанция ──────────────────────────────────
        float dxT = tPos.x - origin.x;
        float dyT = tPos.y - origin.y;
        float dzT = tPos.z - origin.z;
        float dist = std::sqrt(dxT*dxT + dyT*dyT + dzT*dzT);
        if (dist < kMinDistance) continue;

        // ── Время полёта пули ──────────────────────────
        float t = dist / kBulletSpeed + kServerLag;
        if (t < kLeadMin) t = kLeadMin;
        if (t > kLeadMax) t = kLeadMax;

        // ── Компенсация движения СВОЕГО персонажа ──────
        // Продлеваем origin на время, за которое игра применит нашу dir
        float localLead = t * kLocalLeadFactor;
        Vector3 originPred = {
            origin.x + lVel.x * localLead,
            origin.y + lVel.y * localLead,
            origin.z + lVel.z * localLead
        };

        // ── Физическое предсказание цели ───────────────
        float predX = tPos.x + tVel.x * t + 0.5f * tAcc.x * t * t;
        float predZ = tPos.z + tVel.z * t + 0.5f * tAcc.z * t * t;

        float gravTerm = airborne ? -0.5f * kGravity * t * t : 0.0f;
        float predY = tPos.y + tVel.y * t + 0.5f * tAcc.y * t * t
                    + kHeadCenterY + extraY + gravTerm;

        // ── Направление от предсказанного origin ───────
        Vector3 diff = { predX - originPred.x, predY - originPred.y, predZ - originPred.z };
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
        g_tVel = {}; g_tAccel = {}; g_lVel = {};
        g_extraY = 0.0f;
        g_tAirborne = false;
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
// ═══════════════════════════════════════════════════════════════
static Vector3 s_prevTargetPos = {};
static Vector3 s_prevTargetVel = {};
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
    Vector3 rawTVel = {0, 0, 0};
    if (s_havePrevTarget) {
        rawTVel = {
            (tPos.x - s_prevTargetPos.x) / dt,
            (tPos.y - s_prevTargetPos.y) / dt,
            (tPos.z - s_prevTargetPos.z) / dt
        };
        float len = std::sqrt(rawTVel.x*rawTVel.x + rawTVel.y*rawTVel.y + rawTVel.z*rawTVel.z);
        if (len > kMaxVel) {
            float k = kMaxVel / len;
            rawTVel.x *= k; rawTVel.y *= k; rawTVel.z *= k;
        }
    }
    s_prevTargetPos = tPos;
    s_havePrevTarget = true;

    // ─── Ускорение цели ─────────────────────────────────
    Vector3 rawTAcc = {0, 0, 0};
    if (s_havePrevTarget) {
        rawTAcc = {
            (rawTVel.x - s_prevTargetVel.x) / dt,
            (rawTVel.y - s_prevTargetVel.y) / dt,
            (rawTVel.z - s_prevTargetVel.z) / dt
        };
        float len = std::sqrt(rawTAcc.x*rawTAcc.x + rawTAcc.y*rawTAcc.y + rawTAcc.z*rawTAcc.z);
        if (len > kMaxAccel) {
            float k = kMaxAccel / len;
            rawTAcc.x *= k; rawTAcc.y *= k; rawTAcc.z *= k;
        }
    }
    s_prevTargetVel = rawTVel;

    // ─── Скорость стрелка (своя) ────────────────────────
    Vector3 rawLVel = {0, 0, 0};
    if (s_havePrevLocal) {
        rawLVel = {
            (lPos.x - s_prevLocalPos.x) / dt,
            (lPos.y - s_prevLocalPos.y) / dt,
            (lPos.z - s_prevLocalPos.z) / dt
        };
        float len = std::sqrt(rawLVel.x*rawLVel.x + rawLVel.y*rawLVel.y + rawLVel.z*rawLVel.z);
        if (len > kMaxVel) {
            float k = kMaxVel / len;
            rawLVel.x *= k; rawLVel.y *= k; rawLVel.z *= k;
        }
    }
    s_prevLocalPos = lPos;
    s_havePrevLocal = true;

    // ─── Детект прыжка цели ─────────────────────────────
    bool airborne = (std::fabs(rawTVel.y) > kJumpVelThresh)
                 || (std::fabs(rawTAcc.y) > kJumpAccelThresh && rawTVel.y > 0.1f);

    // ─── Контекстные бонусы Y ───────────────────────────
    float extraY = 0.0f;
    if (rawTVel.y >  0.4f) extraY += kAirborneExtraY;
    if (rawTVel.y < -0.4f) extraY += kCrouchExtraY;
    float heightDiff = tPos.y - lPos.y;
    if (heightDiff < -1.5f) extraY += kBelowBiasY;

    {
        std::lock_guard<std::mutex> lk(g_lock);

        // Цель
        g_tVel.x = g_tVel.x * (1.0f - kSmoothVelXZ) + rawTVel.x * kSmoothVelXZ;
        g_tVel.z = g_tVel.z * (1.0f - kSmoothVelXZ) + rawTVel.z * kSmoothVelXZ;

        float yAlpha = airborne ? kSmoothVelYAir : kSmoothVelY;
        g_tVel.y = g_tVel.y * (1.0f - yAlpha) + rawTVel.y * yAlpha;

        g_tAccel.x = g_tAccel.x * (1.0f - kSmoothAccelXZ) + rawTAcc.x * kSmoothAccelXZ;
        g_tAccel.z = g_tAccel.z * (1.0f - kSmoothAccelXZ) + rawTAcc.z * kSmoothAccelXZ;
        g_tAccel.y = g_tAccel.y * (1.0f - kSmoothAccelY)  + rawTAcc.y * kSmoothAccelY;

        // Стрелок
        g_lVel.x = g_lVel.x * (1.0f - kSmoothLocalVel) + rawLVel.x * kSmoothLocalVel;
        g_lVel.y = g_lVel.y * (1.0f - kSmoothLocalVel) + rawLVel.y * kSmoothLocalVel;
        g_lVel.z = g_lVel.z * (1.0f - kSmoothLocalVel) + rawLVel.z * kSmoothLocalVel;

        g_tPos      = tPos;
        g_lPos      = lPos;
        g_extraY    = extraY;
        g_aimPtr    = aimPtr;
        g_tAirborne = airborne;
    }
    g_hasData.store(true, std::memory_order_release);

    // ─── Мгновенный пинг ───────────────────────────────
    {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        float dxT = tPos.x - origin.x;
        float dyT = tPos.y - origin.y;
        float dzT = tPos.z - origin.z;
        float dist = std::sqrt(dxT*dxT + dyT*dyT + dzT*dzT);

        if (dist > kMinDistance) {
            float t = dist / kBulletSpeed + kServerLag;
            if (t < kLeadMin) t = kLeadMin;
            if (t > kLeadMax) t = kLeadMax;

            float localLead = t * kLocalLeadFactor;
            Vector3 originPred = {
                origin.x + g_lVel.x * localLead,
                origin.y + g_lVel.y * localLead,
                origin.z + g_lVel.z * localLead
            };

            float predX = tPos.x + g_tVel.x * t + 0.5f * g_tAccel.x * t * t;
            float predZ = tPos.z + g_tVel.z * t + 0.5f * g_tAccel.z * t * t;

            float gravTerm = airborne ? -0.5f * kGravity * t * t : 0.0f;
            float predY = tPos.y + g_tVel.y * t + 0.5f * g_tAccel.y * t * t
                        + kHeadCenterY + extraY + gravTerm;

            Vector3 diff = { predX - originPred.x, predY - originPred.y, predZ - originPred.z };
            float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
            if (lenSq > kMinLenSq) {
                float inv = 1.0f / std::sqrt(lenSq);
                Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };
                WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
            }
        }
    }
}
