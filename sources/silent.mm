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

static constexpr float kMaxVel         = 30.0f;
static constexpr float kMaxAccel       = 60.0f;
static constexpr float kJumpVelThresh  = 0.6f;
static constexpr float kJumpAccelThresh = 4.0f;

static constexpr float kHeadCenterY    = 0.090f;
static constexpr float kAirborneExtraY = 0.015f;
static constexpr float kCrouchExtraY   = 0.010f;
static constexpr float kBelowBiasY     = 0.015f;

static constexpr float kMinDistance    = 0.5f;

// ── Защита от краша при смене матча ──────────────────────
static constexpr uint64_t kTransitionCooldownMs = 500;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<bool> g_matchReady{false};
static std::atomic<uint64_t> g_transitionTick{0};

static uint64_t g_aimPtr     = 0;
static uint64_t g_localPlayer = 0;
static Vector3  g_tPos   = {};
static Vector3  g_tVel   = {};
static Vector3  g_tAccel = {};
static Vector3  g_lPos   = {};
static float    g_extraY = 0.0f;
static bool     g_tAirborne = false;

static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}
static inline uint64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  WORKER с защитой от протухших указателей
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        // 1) Ждём, пока RunSilentAim разрешит работу
        if (!g_matchReady.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        // 2) Кулдаун после смены матча — Unity успевает освободить старую память
        uint64_t tTick = g_transitionTick.load(std::memory_order_acquire);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        // 3) Есть данные?
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        // 4) Снимок под мьютексом
        uint64_t h, local;
        Vector3 tPos, tVel, tAcc, lPos;
        float   extraY;
        bool    airborne;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            local    = g_localPlayer;
            tPos     = g_tPos;
            tVel     = g_tVel;
            tAcc     = g_tAccel;
            lPos     = g_lPos;
            extraY   = g_extraY;
            airborne = g_tAirborne;
        }

        // 5) Валидация указателей (адресный диапазон)
        if (!validPtr(h) || !validPtr(local)) continue;

        // 6) КЛЮЧЕВАЯ ЗАЩИТА: перечитываем aimPtr из живого local.
        //    Если игра освободила LastAimInfo — увидим несовпадение.
        uint64_t liveAimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
        if (liveAimPtr != h) continue;   // ← память переиспользована, пропускаем

        // 7) Origin как есть из игры
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        float dxT = tPos.x - origin.x;
        float dyT = tPos.y - origin.y;
        float dzT = tPos.z - origin.z;
        float dist = std::sqrt(dxT*dxT + dyT*dyT + dzT*dzT);
        if (dist < kMinDistance) continue;

        float t = dist / kBulletSpeed + kServerLag;
        if (t < kLeadMin) t = kLeadMin;
        if (t > kLeadMax) t = kLeadMax;

        float predX = tPos.x + tVel.x * t + 0.5f * tAcc.x * t * t;
        float predZ = tPos.z + tVel.z * t + 0.5f * tAcc.z * t * t;

        float gravTerm = airborne ? -0.5f * kGravity * t * t : 0.0f;
        float predY = tPos.y + tVel.y * t + 0.5f * tAcc.y * t * t
                    + kHeadCenterY + extraY + gravTerm;

        // RAW вектор (без нормализации — работает лучше)
        Vector3 dir = {
            predX - origin.x,
            predY - origin.y,
            predZ - origin.z
        };

        // 8) Финальная валидация непосредственно перед записью
        //    (после чтения origin память может освободиться — защитный повтор)
        if (!g_matchReady.load(std::memory_order_acquire)) continue;
        if (!validPtr(h)) continue;

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
    g_matchReady.store(false, std::memory_order_release);
    g_transitionTick.store(nowMs(), std::memory_order_release);
    g_lastMatch = 0;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        g_localPlayer = 0;
        g_tVel = {}; g_tAccel = {};
        g_extraY = 0.0f;
        g_tAirborne = false;
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
// ═══════════════════════════════════════════════════════════════
static Vector3 s_prevTargetPos = {};
static Vector3 s_prevTargetVel = {};
static bool    s_havePrevTarget = false;
static std::chrono::steady_clock::time_point s_prevTick;

void RunSilentAim() {
    InitSilentAimThread();

    // ─── Лобби / выключено / нет матча → полный сброс ──
    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        ResetSilentAim();
        s_havePrevTarget = false;
        return;
    }

    // ─── Смена матча → сброс + кулдаун ──
    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        s_havePrevTarget = false;
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
        g_matchReady.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        g_matchReady.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        return;
    }

    Vector3 tPos = HeadPos(target);
    Vector3 lPos = HeadPos(local);
    if (isZeroV3(tPos) || isZeroV3(lPos)) {
        g_hasData.store(false, std::memory_order_release);
        g_matchReady.store(false, std::memory_order_release);
        return;
    }

    // Скорость цели
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

    // Ускорение цели
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

    bool airborne = (std::fabs(rawTVel.y) > kJumpVelThresh)
                 || (std::fabs(rawTAcc.y) > kJumpAccelThresh && rawTVel.y > 0.1f);

    float extraY = 0.0f;
    if (rawTVel.y >  0.4f) extraY += kAirborneExtraY;
    if (rawTVel.y < -0.4f) extraY += kCrouchExtraY;
    float heightDiff = tPos.y - lPos.y;
    if (heightDiff < -1.5f) extraY += kBelowBiasY;

    {
        std::lock_guard<std::mutex> lk(g_lock);

        g_tVel.x = g_tVel.x * (1.0f - kSmoothVelXZ) + rawTVel.x * kSmoothVelXZ;
        g_tVel.z = g_tVel.z * (1.0f - kSmoothVelXZ) + rawTVel.z * kSmoothVelXZ;
        float yAlpha = airborne ? kSmoothVelYAir : kSmoothVelY;
        g_tVel.y = g_tVel.y * (1.0f - yAlpha) + rawTVel.y * yAlpha;

        g_tAccel.x = g_tAccel.x * (1.0f - kSmoothAccelXZ) + rawTAcc.x * kSmoothAccelXZ;
        g_tAccel.z = g_tAccel.z * (1.0f - kSmoothAccelXZ) + rawTAcc.z * kSmoothAccelXZ;
        g_tAccel.y = g_tAccel.y * (1.0f - kSmoothAccelY)  + rawTAcc.y * kSmoothAccelY;

        g_tPos        = tPos;
        g_lPos        = lPos;
        g_extraY      = extraY;
        g_aimPtr      = aimPtr;
        g_localPlayer = local;      // ← теперь worker валидирует по нему
        g_tAirborne   = airborne;
    }

    g_hasData.store(true, std::memory_order_release);

    // Разрешаем работу worker только после кулдауна
    uint64_t tTick = g_transitionTick.load(std::memory_order_acquire);
    if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
        return;   // подождём ещё
    }
    g_matchReady.store(true, std::memory_order_release);

    // ─── Мгновенный пинг ───
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

            float predX = tPos.x + g_tVel.x * t + 0.5f * g_tAccel.x * t * t;
            float predZ = tPos.z + g_tVel.z * t + 0.5f * g_tAccel.z * t * t;
            float gravTerm = airborne ? -0.5f * kGravity * t * t : 0.0f;
            float predY = tPos.y + g_tVel.y * t + 0.5f * g_tAccel.y * t * t
                        + kHeadCenterY + extraY + gravTerm;

            Vector3 dir = { predX - origin.x, predY - origin.y, predZ - origin.z };

            // Повторная валидация перед пингом (память могла освободиться)
            uint64_t liveAimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
            if (liveAimPtr == aimPtr) {
                WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
            }
        }
    }
}
