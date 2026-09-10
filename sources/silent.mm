#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <thread>
#include <mutex>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

static std::mutex        g_lock;
static std::atomic<bool> g_started{false};
static std::atomic<bool> g_active{false};
static uint64_t          g_aimPtr     = 0;
static Vector3           g_predPos    = {};
static Vector3           g_lPos       = {};

static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};
static uint64_t          g_lastMatch      = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    while (true) {
        if (!g_active.load(std::memory_order_acquire) || !aimsilent1 || IsAtLobby(Moudule_Base)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        uint64_t h;
        Vector3 tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_predPos;
            lPos = g_lPos;
        }

        if (!validPtr(h)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) {
            std::this_thread::yield();
            continue;
        }

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
        
        std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true)) {
        std::thread(SilentWorker).detach();
    }
}

void ResetSilentAim() {
    g_active.store(false, std::memory_order_release);
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        ResetSilentAim();
        return;
    }

    if (cachedMatch != g_lastMatch) {
        g_lastMatch = cachedMatch;
        ResetSilentAim();
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_active.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_active.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_active.store(false, std::memory_order_release);
        return;
    }

    if (g_prevTargetPos.x != 0.0f || g_prevTargetPos.y != 0.0f || g_prevTargetPos.z != 0.0f) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float distSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        if (distSq < 25.0f) {
            g_targetVelocity = delta;
        } else {
            g_targetVelocity = {0.0f, 0.0f, 0.0f};
        }
    } else {
        g_targetVelocity = {0.0f, 0.0f, 0.0f};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    Vector3 predPos = {
        tPos.x + g_targetVelocity.x * 0.06f,
        tPos.y + g_targetVelocity.y * 0.06f,
        tPos.z + g_targetVelocity.z * 0.06f
    };

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr  = aimPtr;
        g_predPos = predPos;
        g_lPos    = HeadPos(local);
    }

    g_active.store(true, std::memory_order_release);
}
