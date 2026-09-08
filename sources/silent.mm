#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t cachedMatch;
extern bool     aimsilent1;
extern uint64_t g_SilentBestTarget;

// ======== Оффсеты (кроме kAimRotation, уже есть в offset.h) ========
static constexpr uint64_t kHit_RayDir   = 0x40;
static constexpr uint64_t kHit_StartPos = 0x4C;
static constexpr uint64_t kHit_Scatter  = 0x5C;
static constexpr uint64_t kWpn_CostAmmo = 0x7B8;

// Четыре слота HitObjectInfo
static constexpr uint64_t kHitObjOffs[4] = {
    0xDC8, 0xDD0, 0xA90, 0xAA0
};

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_localPlayer = 0;
static uint64_t          g_targetPlayer = 0;

// ======== Вспомогательные функции ========
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return Vector3{};
    uint64_t head = getHead(pawn);
    return isVaildPtr(head) ? getPositionExt(head) : Vector3{};
}

// ======== Поток ========
static void SilentWorker() {
    while (true) {
        std::this_thread::yield();

        if (!g_hasData.load(std::memory_order_relaxed)) continue;

        uint64_t local, target;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local  = g_localPlayer;
            target = g_targetPlayer;
        }
        if (!isVaildPtr(local) || !isVaildPtr(target)) {
            g_hasData.store(false, std::memory_order_relaxed);
            continue;
        }

        Vector3 targetHead = HeadPos(target);
        if (targetHead.x == 0.0f && targetHead.y == 0.0f && targetHead.z == 0.0f) {
            g_hasData.store(false, std::memory_order_relaxed);
            continue;
        }

        Vector3 localHead = HeadPos(local);
        if (localHead.x == 0.0f && localHead.y == 0.0f && localHead.z == 0.0f)
            localHead = getPositionExt(getHip(local));

        for (int i = 0; i < 4; ++i) {
            uint64_t hitObj = ReadAddr<uint64_t>(local + kHitObjOffs[i]);
            if (!isVaildPtr(hitObj)) continue;

            Vector3 start = ReadAddr<Vector3>(hitObj + kHit_StartPos);
            if (start.x == 0.0f && start.y == 0.0f && start.z == 0.0f)
                start = localHead;

            Vector3 diff = targetHead - start;
            float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
            if (lenSq <= 0.0001f) continue;

            float inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = diff * inv;

            WriteAddr<Vector3>(hitObj + kHit_RayDir, dir);
            WriteAddr<float>(hitObj + kHit_Scatter, 0.0f);
        }
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

// ======== Сброс ========
void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lk(g_lock);
    g_localPlayer  = 0;
    g_targetPlayer = 0;
    g_SilentBestTarget = 0;
}

// ======== Основная функция ========
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        ResetSilentAim();
        return;
    }

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local) || get_CurHP(local) <= 0) {
        ResetSilentAim();
        return;
    }

    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(target) || get_CurHP(target) <= 0) {
        ResetSilentAim();
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        ResetSilentAim();
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_localPlayer  = local;
        g_targetPlayer = target;
    }
    g_hasData.store(true, std::memory_order_relaxed);
}
