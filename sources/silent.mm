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

static constexpr float kPredictionTime = 0.06f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr         = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_lastLocal      = 0;
static uint64_t          g_lastTarget     = 0;
static uint64_t          g_lastMatch      = 0;

static std::chrono::steady_clock::time_point g_lastTick;
static float g_lastDt = 0.0166f;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Общий помощник для записи направления. Вызывается и из воркера, и из главного потока.
static inline void WriteRayDir(uint64_t aimPtr, const Vector3 &targetPos,
                               const Vector3 &vel, const Vector3 &fallbackOrigin) {
    if (!validPtr(aimPtr)) return;

    Vector3 predPos = {
        targetPos.x + vel.x * kPredictionTime,
        targetPos.y + vel.y * kPredictionTime,
        targetPos.z + vel.z * kPredictionTime
    };

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
        origin = fallbackOrigin;

    Vector3 diff  = { predPos.x - origin.x, predPos.y - origin.y, predPos.z - origin.z };
    float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
    if (lenSq <= 0.0001f) return;

    float   inv = 1.0f / std::sqrt(lenSq);
    Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

    WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            lPos = g_lPos;
            vel  = g_targetVelocity;
        }
        if (!validPtr(h)) {
            g_hasData.store(false, std::memory_order_release);
            continue;
        }

        WriteRayDir(h, tPos, vel, lPos);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastLocal      = 0;
    g_lastTarget     = 0;
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}

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

    auto now = std::chrono::steady_clock::now();
    float dt = 0.0f;
    if (g_lastTick.time_since_epoch().count() != 0)
        dt = std::chrono::duration<float>(now - g_lastTick).count();
    g_lastTick = now;

    if (dt <= 0.0f || dt > 0.2f) dt = g_lastDt;
    g_lastDt = dt;

    if (g_prevTargetPos.x != 0.0f || g_prevTargetPos.y != 0.0f || g_prevTargetPos.z != 0.0f) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float distSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        if (distSq < 25.0f) {
            g_targetVelocity = { delta.x / dt, delta.y / dt, delta.z / dt };
        } else {
            g_targetVelocity = {0.0f, 0.0f, 0.0f};
        }
    } else {
        g_targetVelocity = {0.0f, 0.0f, 0.0f};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    Vector3 localHead = HeadPos(local);

    Vector3 vel = g_targetVelocity;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_lPos   = localHead;
    }
    g_hasData.store(true, std::memory_order_release);

    // Прямая запись RayDir с ГЛАВНОГО потока в тот же кадр, где ESP обновил цель.
    // Воркер продолжает писать параллельно, это лишь увеличивает шанс попасть
    // в окно между «игровой поток читает RayDir» и «игровой поток пишет RayDir».
    WriteRayDir(aimPtr, tPos, vel, localHead);
}
