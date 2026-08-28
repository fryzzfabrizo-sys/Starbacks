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
static constexpr uint64_t kHit_StartPos        = 0x4C;
static constexpr uint64_t kHit_Distance        = 0x5C; // пишем реальную дистанцию
static constexpr uint64_t kWpn_CostAmmo        = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
// Атомарные указатели — тред читает их без лока каждую итерацию
static std::atomic<uint64_t> g_aimPtr  {0};
static std::atomic<uint64_t> g_target  {0};
static std::atomic<uint64_t> g_local   {0};

static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        uint64_t h      = g_aimPtr.load(std::memory_order_relaxed);
        uint64_t target = g_target.load(std::memory_order_relaxed);
        uint64_t local  = g_local.load(std::memory_order_relaxed);

        if (!isValidIOSPtr(h) || !isVaildPtr(target)) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
            continue;
        }

        // Читаем позицию цели прямо здесь — свежая на каждой итерации
        Vector3 tPos = HeadPos(target);
        if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
            continue;
        }
        tPos.y += 0.05f;

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = HeadPos(local);

        Vector3 diff  = { tPos.x-origin.x, tPos.y-origin.y, tPos.z-origin.z };
        float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq <= 0.0001f) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
            continue;
        }

        float   inv  = 1.0f / std::sqrt(lenSq);
        Vector3 dir  = { diff.x*inv, diff.y*inv, diff.z*inv };
        float   dist = std::sqrt(lenSq);

        WriteAddr<Vector3>(h + kHit_RayDir,   dir);
        WriteAddr<float>  (h + kHit_Distance,  dist);

        // При активном огне — tight loop без sleep чтобы поймать окно пакета
        // При простое — 1µs чтобы не нагружать CPU
        uint64_t local2 = g_local.load(std::memory_order_relaxed);
        bool firing = isVaildPtr(local2) && get_IsFiring(local2);
        if (!firing) {
            std::this_thread::sleep_for(std::chrono::microseconds(1));
        }
        // При firing: нет sleep — максимальная частота записи
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
        g_aimPtr.store(0, std::memory_order_relaxed);
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        g_aimPtr.store(0, std::memory_order_relaxed);
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        g_aimPtr.store(0, std::memory_order_relaxed);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isValidIOSPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        g_aimPtr.store(0, std::memory_order_relaxed);
        return;
    }

    // Атомарное обновление — тред читает без блокировки
    g_aimPtr.store(aimPtr,  std::memory_order_relaxed);
    g_target.store(target,  std::memory_order_relaxed);
    g_local .store(local,   std::memory_order_relaxed);
    g_hasData.store(true,   std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_aimPtr.store(0,  std::memory_order_relaxed);
    g_target.store(0,  std::memory_order_relaxed);
    g_local .store(0,  std::memory_order_relaxed);
}
