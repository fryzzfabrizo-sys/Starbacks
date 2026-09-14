// silent.mm
// Silent aim через ITransformNode головы (0x638).
// Prediction для движущихся и прыгающих врагов.
// Всё считается в воркере — main thread только выставляет цель.

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <thread>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Offsets (из твоего рабочего файла) ──────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

// ─── Prediction ──────────────────────────────────────────
static constexpr float kPredictTimeSec = 0.03f;   // 30мс упреждения
static constexpr float kMaxVel         = 20.0f;   // м/с — отсекаем мусор
static constexpr float kMinDt          = 0.001f;
static constexpr float kMaxDt          = 0.050f;

// ─── Shared state ────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr     = 0;
static uint64_t          g_targetPawn = 0;
static uint64_t          g_lastMatch  = 0;

// Prediction state — обновляется только в воркере
static uint64_t g_predPawn    = 0;
static Vector3  g_predLastPos = {0, 0, 0};
static std::chrono::steady_clock::time_point g_predLastTime;
static bool     g_predValid   = false;

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

static Vector3 PredictHead(uint64_t pawn, const Vector3& cur) {
    Vector3 result = cur;

    if (pawn != g_predPawn) {
        g_predPawn     = pawn;
        g_predLastPos  = cur;
        g_predLastTime = std::chrono::steady_clock::now();
        g_predValid    = true;
        return result;
    }

    if (!g_predValid) {
        g_predLastPos  = cur;
        g_predLastTime = std::chrono::steady_clock::now();
        g_predValid    = true;
        return result;
    }

    auto now = std::chrono::steady_clock::now();
    float dt = std::chrono::duration<float>(now - g_predLastTime).count();

    if (dt < kMinDt || dt > kMaxDt) {
        g_predLastPos  = cur;
        g_predLastTime = now;
        return result;
    }

    Vector3 vel = {
        (cur.x - g_predLastPos.x) / dt,
        (cur.y - g_predLastPos.y) / dt,
        (cur.z - g_predLastPos.z) / dt
    };

    float vlen = sqrtf(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z);
    if (vlen > 0.001f && vlen < kMaxVel) {
        result.x += vel.x * kPredictTimeSec;
        result.y += vel.y * kPredictTimeSec;
        result.z += vel.z * kPredictTimeSec;
    }

    g_predLastPos  = cur;
    g_predLastTime = now;
    return result;
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        uint64_t target;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h      = g_aimPtr;
            target = g_targetPawn;
        }

        if (!validPtr(h) || !validPtr(target)) {
            std::this_thread::yield();
            continue;
        }

        // Читаем позицию головы каждый тик — свежие данные
        Vector3 rawPos = HeadPos(target);
        if (!validVec(rawPos)) {
            std::this_thread::yield();
            continue;
        }

        // Prediction на основе velocity
        Vector3 tPos = PredictHead(target, rawPos);

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(h + kHit_RayDir, diff);
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
    g_aimPtr     = 0;
    g_targetPawn = 0;
    g_predPawn   = 0;
    g_predValid  = false;
}

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

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr     = aimPtr;
        g_targetPawn = target;
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенная первая запись — чтобы сработало с первого кадра
    Vector3 tPos = HeadPos(target);
    if (validVec(tPos)) {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(aimPtr + kHit_RayDir, diff);
    }
}
