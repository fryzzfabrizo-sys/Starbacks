#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

static constexpr uint64_t kPawn_Velocity       = 0x140;

static constexpr float kHeadCenterY = 0.055f;
static constexpr float kBulletSpeed = 5000.0f; // Увеличено для минимального упреждения на хитскане

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t g_aimPtr   = 0;
static uint64_t g_aimKlass = 0;
static Vector3  g_headPos  = {};
static Vector3  g_localPos = {};
static Vector3  g_targetVel = {};

static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static inline Vector3 NormalizeVector(const Vector3& v) {
    float len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len < 1e-5f) return {0.0f, 0.0f, 1.0f};
    return {v.x / len, v.y / len, v.z / len};
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return validPtr(t) ? getPositionExt(t) : Vector3{};
}

static Vector3 GetPlayerVelocity(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    return ReadAddr<Vector3>(pawn + kPawn_Velocity);
}

static inline void ApplySilentWrite(uint64_t h, uint64_t klass, const Vector3& rawHead, const Vector3& lPos, const Vector3& velocity) {
    if (!validPtr(h)) return;

    uint64_t curKlass = ReadAddr<uint64_t>(h + 0);
    if (curKlass != klass || !validPtr(curKlass)) return;

    Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
    if (isZeroV3(origin)) {
        origin = lPos;
    }

    float dist = std::sqrt(
        std::pow(rawHead.x - origin.x, 2) +
        std::pow(rawHead.y - origin.y, 2) +
        std::pow(rawHead.z - origin.z, 2)
    );

    float timeToTarget = dist / kBulletSpeed;

    Vector3 predictedHead = rawHead;
    predictedHead.x += velocity.x * timeToTarget;
    predictedHead.y += (velocity.y * timeToTarget) - (0.5f * 9.8f * timeToTarget * timeToTarget * 0.1f);
    predictedHead.z += velocity.z * timeToTarget;

    predictedHead.y += kHeadCenterY;

    // Исправленный порядок вычитания (от старта к цели)
    Vector3 diff = {
        predictedHead.x - origin.x,
        predictedHead.y - origin.y,
        predictedHead.z - origin.z
    };

    Vector3 dir = NormalizeVector(diff);
    WriteAddr<Vector3>(h + kHit_RayDir, dir);
}

static void SilentWorker() {
    while (g_started.load(std::memory_order_relaxed)) {
        if (!g_hasData.load(std::memory_order_relaxed) || !aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        uint64_t h     = 0;
        uint64_t klass = 0;
        Vector3 headPos, localPos, targetVel;
        
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h         = g_aimPtr;
            klass     = g_aimKlass;
            headPos   = g_headPos;
            localPos  = g_localPos;
            targetVel = g_targetVel;
        }

        if (!validPtr(h)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        uint64_t curKlass = ReadAddr<uint64_t>(h + 0);
        if (curKlass != klass || !validPtr(curKlass)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }

        ApplySilentWrite(h, klass, headPos, localPos, targetVel);
        
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
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
        g_aimPtr    = 0;
        g_aimKlass  = 0;
        g_headPos   = {};
        g_localPos  = {};
        g_targetVel = {};
    }
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
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

    uint64_t klass = ReadAddr<uint64_t>(aimPtr + 0);
    if (!validPtr(klass)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 head = HeadPos(target);
    if (isZeroV3(head)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 lPos = HeadPos(local);
    Vector3 vel  = GetPlayerVelocity(target);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr    = aimPtr;
        g_aimKlass  = klass;
        g_headPos   = head;
        g_localPos  = lPos;
        g_targetVel = vel;
    }
    g_hasData.store(true, std::memory_order_release);

    ApplySilentWrite(aimPtr, klass, head, lPos, vel);
}
