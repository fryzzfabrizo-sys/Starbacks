#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr        = 0;
static Vector3           g_tPos          = {};
static Vector3           g_lPos          = {};
static Vector3           g_prevTargetPos = {};
static Vector3           g_targetVelocity= {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
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
        if (!isVaildPtr(h)) { g_hasData.store(false, std::memory_order_release); continue; }

        Vector3 pred = { tPos.x + vel.x*0.06f, tPos.y + vel.y*0.06f, tPos.z + vel.z*0.06f };

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0 && origin.y == 0 && origin.z == 0) origin = lPos;

        Vector3 diff = { pred.x-origin.x, pred.y-origin.y, pred.z-origin.z };
        float len = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (len <= 0.0001f) continue;

        float inv = 1.0f / std::sqrt(len);
        WriteAddr<Vector3>(h + kHit_RayDir, {diff.x*inv, diff.y*inv, diff.z*inv});
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isVaildPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0 && tPos.y == 0 && tPos.z == 0) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    if (g_prevTargetPos.x != 0 || g_prevTargetPos.y != 0 || g_prevTargetPos.z != 0) {
        g_targetVelocity = { tPos.x-g_prevTargetPos.x, tPos.y-g_prevTargetPos.y, tPos.z-g_prevTargetPos.z };
    } else {
        g_targetVelocity = {};
    }
    g_prevTargetPos = tPos;
    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_lPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}
