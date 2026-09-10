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

// ── Захват головы ─────────────────────────────────────────
static constexpr float kHeadCenterY = 0.055f;

// ── Микро-лид для движущихся врагов ──────────────────────
static constexpr float kLeadTime = 0.025f;
static constexpr float kMaxVel   = 30.0f;

// ── Сглаживание скорости ────────────────────────────────
static constexpr float kSmoothVelXZ = 0.70f;
static constexpr float kSmoothVelY  = 0.85f;

// ── Защита от краша при смене матча ──────────────────────
static constexpr uint64_t kTransitionCooldownMs = 500;

// ═══════════════════════════════════════════════════════════════
//  Вся математика (лид + EMA + центр черепа) считается
//  один раз в кадр в RunSilentAim. Worker в горячем цикле
//  делает МИНИМУМ: Read origin + 3 вычитания + Write.
// ═══════════════════════════════════════════════════════════════

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<uint64_t> g_transitionTick{0};

static uint64_t g_aimPtr     = 0;
static Vector3  g_predTarget = {};   // предвычисленная цель (head + lead)
static Vector3  g_localPos   = {};

static uint64_t g_lastMatch = 0;

static Vector3 s_prevTargetPos = {};
static bool    s_havePrevTarget = false;
static std::chrono::steady_clock::time_point s_prevTick;

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
//  WORKER — минимум операций. Без sqrt. Без EMA. Без чтения Head.
//  Только Read origin + 3 вычитания + Write.
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_acquire);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::microseconds(500));
            continue;
        }

        // Снимок: aimPtr, predTarget, localPos
        uint64_t h;
        Vector3 pred, localPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            pred     = g_predTarget;
            localPos = g_localPos;
        }
        if (!validPtr(h)) {
            std::this_thread::yield();
            continue;
        }

        // Один ReadAddr
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = localPos;

        // Три вычитания
        Vector3 dir = { pred.x - origin.x, pred.y - origin.y, pred.z - origin.z };

        // Один WriteAddr
        WriteAddr<Vector3>(h + kHit_RayDir, dir);

        // Максимальная частота без sleep
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
    g_transitionTick.store(nowMs(), std::memory_order_release);
    g_lastMatch = 0;
    s_havePrevTarget = false;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        g_predTarget = {};
        g_localPos = {};
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — вся математика здесь (60 fps)
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
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        return;
    }

    Vector3 head = HeadPos(target);
    if (isZeroV3(head)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // ─── Скорость цели (raw → clip) ─────────────────────
    Vector3 rawVel = {0, 0, 0};
    if (s_havePrevTarget) {
        rawVel = {
            (head.x - s_prevTargetPos.x) / dt,
            (head.y - s_prevTargetPos.y) / dt,
            (head.z - s_prevTargetPos.z) / dt
        };
        float lenSq = rawVel.x*rawVel.x + rawVel.y*rawVel.y + rawVel.z*rawVel.z;
        if (lenSq > kMaxVel * kMaxVel) {
            float invLen = kMaxVel / std::sqrt(lenSq);
            rawVel.x *= invLen; rawVel.y *= invLen; rawVel.z *= invLen;
        }
    }
    s_prevTargetPos = head;
    s_havePrevTarget = true;

    // ─── EMA ────────────────────────────────────────────
    static Vector3 s_vel = {0, 0, 0};
    s_vel.x = s_vel.x * (1.0f - kSmoothVelXZ) + rawVel.x * kSmoothVelXZ;
    s_vel.z = s_vel.z * (1.0f - kSmoothVelXZ) + rawVel.z * kSmoothVelXZ;
    s_vel.y = s_vel.y * (1.0f - kSmoothVelY)  + rawVel.y * kSmoothVelY;

    // ─── Финальная предвычисленная цель ─────────────────
    Vector3 pred = {
        head.x + s_vel.x * kLeadTime,
        head.y + kHeadCenterY + s_vel.y * kLeadTime,
        head.z + s_vel.z * kLeadTime
    };

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr     = aimPtr;
        g_predTarget = pred;
        g_localPos   = lPos;
    }
    g_hasData.store(true, std::memory_order_release);
}
