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
extern bool aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir = 0x40;
static constexpr uint64_t kHit_StartPos = 0x4C;

static_assert(sizeof(Vector3) == 0xC, "Vector3 layout must be 12 bytes");

static std::mutex g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t g_aimPtr = 0;
static uint64_t g_local = 0;
static Vector3 g_tPos = {};
static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool finiteVector(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return validPtr(t) ? getPositionExt(t) : Vector3{};
}

static bool MakeAimDirection(uint64_t aimPtr, uint64_t local, const Vector3& targetPos, Vector3& outDir) {
    if (!validPtr(aimPtr) || !validPtr(local) || !finiteVector(targetPos))
        return false;

    Vector3 origin{};
    if (!_read(static_cast<long>(aimPtr + kHit_StartPos), &origin, sizeof(origin)))
        return false;

    if (!finiteVector(origin))
        return false;

    if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f) {
        origin = HeadPos(local);
        if (!finiteVector(origin) ||
            (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f))
            return false;
    }

    Vector3 diff = {
        targetPos.x - origin.x,
        targetPos.y - origin.y,
        targetPos.z - origin.z
    };

    if (!finiteVector(diff))
        return false;

    float lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
    if (!std::isfinite(lenSq) || lenSq <= 0.0001f)
        return false;

    float inv = 1.0f / std::sqrt(lenSq);
    if (!std::isfinite(inv))
        return false;

    outDir = {
        diff.x * inv,
        diff.y * inv,
        diff.z * inv
    };

    return finiteVector(outDir);
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
            continue;
        }

        {
            std::lock_guard<std::mutex> lk(g_lock);

            if (!g_hasData.load(std::memory_order_acquire) ||
                !validPtr(g_aimPtr) ||
                !validPtr(g_local))
                continue;

            Vector3 dir;
            if (MakeAimDirection(g_aimPtr, g_local, g_tPos, dir)) {
                if (!WriteAddr<Vector3>(static_cast<long>(g_aimPtr + kHit_RayDir), dir)) {
                    g_aimPtr = 0;
                    g_local = 0;
                    g_tPos = {};
                    g_hasData.store(false, std::memory_order_release);
                }
            }
        }

        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
}

void InitSilentAimThread() {
    bool expected = false;
    if (g_started.compare_exchange_strong(expected, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
    g_local = 0;
    g_tPos = {};
    g_hasData.store(false, std::memory_order_release);
}

void RunSilentAim() {
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

    uint64_t local = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!validPtr(local) || !validPtr(target)) {
        ResetSilentAim();
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(static_cast<long>(local + kPlayer_LastAimInfo));
    if (!validPtr(aimPtr)) {
        ResetSilentAim();
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (!finiteVector(tPos) ||
        (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f)) {
        ResetSilentAim();
        return;
    }

    InitSilentAimThread();

    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = aimPtr;
    g_local = local;
    g_tPos = tPos;
    g_hasData.store(true, std::memory_order_release);
}
