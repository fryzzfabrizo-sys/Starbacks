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

static constexpr float kHeadCenterY = 0.055f;
static constexpr float kLeadTime    = 0.025f;
static constexpr float kMaxVel      = 30.0f;
static constexpr float kSmoothVelXZ = 0.70f;
static constexpr float kSmoothVelY  = 0.85f;

// Смещение origin вниз от головы (чтобы origin был в "груди", а не в черепе)
// Это даёт более естественный угол луча — одинаково работает вверх и вниз.
static constexpr float kOriginDownY = 0.30f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t g_aimPtr   = 0;
static Vector3  g_headPos  = {};
static Vector3  g_headVel  = {};
static Vector3  g_localPos = {};

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
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  WORKER — пишем И origin, И direction
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        std::this_thread::yield();

        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t h;
        Vector3 headPos, headVel, localPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            headPos  = g_headPos;
            headVel  = g_headVel;
            localPos = g_localPos;
        }
        if (!validPtr(h)) continue;

        // ═══ СТАБИЛЬНЫЙ ORIGIN — голова локального игрока, чуть вниз ═══
        Vector3 origin = {
            localPos.x,
            localPos.y - kOriginDownY,
            localPos.z
        };

        // Пишем origin в память — движок возьмёт его как точку старта
        WriteAddr<Vector3>(h + kHit_StartPos, origin);

        // Предсказание позиции цели
        Vector3 pred = {
            headPos.x + headVel.x * kLeadTime,
            headPos.y + headVel.y * kLeadTime,
            headPos.z + headVel.z * kLeadTime
        };

        // Direction от нашего стабильного origin к предсказанной позиции
        Vector3 dir = {
            pred.x - origin.x,
            pred.y - origin.y,
            pred.z - origin.z
        };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
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
    s_havePrevTarget = false;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        g_headPos = {};
        g_headVel = {};
        g_localPos = {};
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
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

    Vector3 rawVel = {0, 0, 0};
    if (s_havePrevTarget) {
        rawVel = {
            (head.x - s_prevTargetPos.x) / dt,
            (head.y - s_prevTargetPos.y) / dt,
            (head.z - s_prevTargetPos.z) / dt
        };
        float len = std::sqrt(rawVel.x*rawVel.x + rawVel.y*rawVel.y + rawVel.z*rawVel.z);
        if (len > kMaxVel) {
            float k = kMaxVel / len;
            rawVel.x *= k; rawVel.y *= k; rawVel.z *= k;
        }
    }
    s_prevTargetPos = head;
    s_havePrevTarget = true;

    head.y += kHeadCenterY;

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);

        g_headVel.x = g_headVel.x * (1.0f - kSmoothVelXZ) + rawVel.x * kSmoothVelXZ;
        g_headVel.z = g_headVel.z * (1.0f - kSmoothVelXZ) + rawVel.z * kSmoothVelXZ;
        g_headVel.y = g_headVel.y * (1.0f - kSmoothVelY)  + rawVel.y * kSmoothVelY;

        g_aimPtr   = aimPtr;
        g_headPos  = head;
        g_localPos = lPos;
    }
    g_hasData.store(true, std::memory_order_release);

    // ═══ МГНОВЕННЫЙ ПИНГ ═══
    {
        Vector3 origin = {
            lPos.x,
            lPos.y - kOriginDownY,
            lPos.z
        };

        // Пишем origin
        WriteAddr<Vector3>(aimPtr + kHit_StartPos, origin);

        Vector3 pred = {
            head.x + g_headVel.x * kLeadTime,
            head.y + g_headVel.y * kLeadTime,
            head.z + g_headVel.z * kLeadTime
        };

        Vector3 dir = {
            pred.x - origin.x,
            pred.y - origin.y,
            pred.z - origin.z
        };
        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
    }
}
