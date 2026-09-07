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

// iOS ARM64 OB54 оффсеты (из OB53 dump + сдвиг)
// 0xDC8 = обычный FF, 0xDD0 = MaxGame/CS режим (из реверса CateFF)
static constexpr uint64_t kPlayer_LastAimInfo  = 0xDC8;
static constexpr uint64_t kPlayer_LastAimInfo2 = 0xDD0;
static constexpr uint64_t kHit_RayDir         = 0x40;  // Vector3 RayDir (только это)
static constexpr uint64_t kHit_StartPos       = 0x4C;  // Vector3 StartPosition (читаем)
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr  = 0;
static uint64_t          g_local2  = 0; // для DD0 слота
static Vector3           g_tPos    = {};
static Vector3           g_lPos    = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t h, local2;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h      = g_aimPtr;
            tPos   = g_tPos;
            lPos   = g_lPos;
            local2 = g_local2;
        }
        if (!isVaildPtr(h)) continue;

        // Читаем реальный StartPos из объекта
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { tPos.x-origin.x, tPos.y-origin.y, tPos.z-origin.z };
        float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };

        // Пишем RayDir в оба слота (DC8 = обычный, DD0 = MaxGame)
        WriteAddr<Vector3>(h + kHit_RayDir, dir);

        uint64_t h2 = ReadAddr<uint64_t>(local2 + kPlayer_LastAimInfo2);
        if (isVaildPtr(h2) && h2 >= 0x100000000ULL) {
            Vector3 origin2 = ReadAddr<Vector3>(h2 + kHit_StartPos);
            if (origin2.x == 0.0f && origin2.y == 0.0f && origin2.z == 0.0f) origin2 = lPos;
            Vector3 diff2 = { tPos.x-origin2.x, tPos.y-origin2.y, tPos.z-origin2.z };
            float len2 = diff2.x*diff2.x + diff2.y*diff2.y + diff2.z*diff2.z;
            if (len2 > 0.0001f) {
                float inv2 = 1.0f / std::sqrt(len2);
                WriteAddr<Vector3>(h2 + kHit_RayDir, { diff2.x*inv2, diff2.y*inv2, diff2.z*inv2 });
            }
        }
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

    // Гранаты и IceWall не тратят ammo
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
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // +0.05 Y — как в Silent.cpp, чтобы попадать в центр головы
    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_local2 = local;
        g_tPos   = tPos;
        g_lPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}
