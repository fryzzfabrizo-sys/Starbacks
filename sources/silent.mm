// silent.mm
// Silent aim через ITransformNode головы (0x638)
// + prediction по X/Z для движущихся целей

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Prediction ──────────────────────────────────────────
static constexpr float kPredictTimeSec = 0.02f;
static constexpr float kMaxVelXZ       = 12.0f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

// Prediction state
static uint64_t          g_predPawn    = 0;
static Vector3           g_predLastPos = {};
static std::chrono::steady_clock::time_point g_predLastTime;
static bool              g_predValid   = false;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}
static Vector3 BonePos(uint64_t pawn, uint64_t boneOffset) {
    if (!validPtr(pawn)) return {};
    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + boneOffset);
    if (!validPtr(bodyPart)) return {};
    uint64_t node = ReadAddr<uint64_t>(bodyPart + kSilentBodyPartTransformOffset);
    if (!validPtr(node)) return {};
    return getPositionExt(node);
}
static Vector3 HeadPos(uint64_t pawn) {
    return BonePos(pawn, kSilentHeadNodeOffset);
}

// Prediction по X/Z (Y не трогаем — иначе уводит вверх при прыжках)
static Vector3 PredictHeadXZ(uint64_t pawn, const Vector3& cur) {
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

    if (dt < 0.002f || dt > 0.100f) {
        g_predLastPos  = cur;
        g_predLastTime = now;
        return result;
    }

    float vx = (cur.x - g_predLastPos.x) / dt;
    float vz = (cur.z - g_predLastPos.z) / dt;
    float vlenXZ = sqrtf(vx * vx + vz * vz);

    if (vlenXZ > 0.001f && vlenXZ < kMaxVelXZ) {
        result.x += vx * kPredictTimeSec;
        result.z += vz * kPredictTimeSec;
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
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
        }
        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }
        Vector3 origin = ReadAddr<Vector3>(h + kHitStartPositionOffset);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(h + kHitRayDirectionOffset, diff);
        std::atomic_thread_fence(std::memory_order_seq_cst);
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
    g_aimPtr    = 0;
    g_tPos      = {};
    g_predPawn  = 0;
    g_predValid = false;
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

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kLastAimInfoOffset);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 rawHead = HeadPos(target);
    if (!validVec(rawHead)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = PredictHeadXZ(target, rawHead);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
    }
    g_hasData.store(true, std::memory_order_release);

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHitStartPositionOffset);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };
    WriteAddr<Vector3>(aimPtr + kHitRayDirectionOffset, diff);
    std::atomic_thread_fence(std::memory_order_seq_cst);
}
