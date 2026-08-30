#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// OB54 iOS 64-bit
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kPlayer_IsAiming    = 0x4A0;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

struct SilentState {
    uint64_t aimPtr = 0;
    uint64_t local  = 0;
    uint64_t target = 0;
};

static std::mutex              g_lock;
static std::condition_variable g_cv;

static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<bool> g_stop{false};

static SilentState g_state{};

static std::thread g_worker;

static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL &&
           p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool isValidVector(const Vector3& v) {
    return std::isfinite(v.x) &&
           std::isfinite(v.y) &&
           std::isfinite(v.z);
}

static inline bool isZeroVector(const Vector3& v) {
    return v.x == 0.0f &&
           v.y == 0.0f &&
           v.z == 0.0f;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn))
        return {};

    uint64_t t = getHead(pawn);

    if (!isVaildPtr(t))
        return {};

    Vector3 pos = getPositionExt(t);

    if (!isValidVector(pos))
        return {};

    return pos;
}

static void ClearSilentState() {
    {
        std::lock_guard<std::mutex> lk(g_lock);

        g_state = {};
        g_hasData.store(false, std::memory_order_release);
    }

    g_cv.notify_one();
}

static void SilentWorker() {
    while (!g_stop.load(std::memory_order_acquire)) {

        SilentState state;

        {
            std::unique_lock<std::mutex> lk(g_lock);

            g_cv.wait(lk, [] {
                return g_stop.load(std::memory_order_acquire) ||
                       g_hasData.load(std::memory_order_acquire);
            });

            if (g_stop.load(std::memory_order_acquire))
                break;

            state = g_state;
        }

        if (!isValidIOSPtr(state.aimPtr) ||
            !isVaildPtr(state.local) ||
            !isVaildPtr(state.target)) {

            ClearSilentState();
            continue;
        }

        Vector3 tPos = HeadPos(state.target);

        if (!isValidVector(tPos) || isZeroVector(tPos))
            continue;

        tPos.y += 0.05f;

        Vector3 origin =
            ReadAddr<Vector3>(state.aimPtr + kHit_StartPos);

        if (!isValidVector(origin))
            continue;

        if (isZeroVector(origin)) {
            origin = HeadPos(state.local);

            if (!isValidVector(origin) ||
                isZeroVector(origin)) {
                continue;
            }
        }

        Vector3 dir{
            tPos.x - origin.x,
            tPos.y - origin.y,
            tPos.z - origin.z
        };

        if (!isValidVector(dir) || isZeroVector(dir))
            continue;

        WriteAddr<Vector3>(
            state.aimPtr + kHit_RayDir,
            dir
        );
    }
}

void InitSilentAimThread() {
    bool expected = false;

    if (!g_started.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acq_rel)) {
        return;
    }

    g_stop.store(false, std::memory_order_release);

    g_worker = std::thread([] {
        SilentWorker();
    });
}

void ShutdownSilentAimThread() {
    bool expected = false;

    if (!g_started.compare_exchange_strong(
            expected,
            false,
            std::memory_order_acq_rel)) {
        return;
    }

    g_stop.store(true, std::memory_order_release);
    g_hasData.store(false, std::memory_order_release);

    g_cv.notify_all();

    if (g_worker.joinable())
        g_worker.join();

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_state = {};
    }

    g_stop.store(false, std::memory_order_release);
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 ||
        !isVaildPtr(cachedMatch)) {

        ClearSilentState();
        return;
    }

    uint64_t local =
        getLocalPlayer(cachedMatch);

    uint64_t target =
        g_SilentBestTarget;

    if (!isVaildPtr(local) ||
        !isVaildPtr(target)) {

        ClearSilentState();
        return;
    }

    uint64_t wpn =
        WeaponOnHand(local);

    if (isVaildPtr(wpn)) {

        bool costAmmo =
            ReadAddr<bool>(
                wpn + kWpn_CostAmmo
            );

        if (!costAmmo) {
            ClearSilentState();
            return;
        }
    }

    bool isAiming =
        ReadAddr<bool>(
            local + kPlayer_IsAiming
        );

    if (!isAiming) {
        ClearSilentState();
        return;
    }

    uint64_t aimPtr =
        ReadAddr<uint64_t>(
            local + kPlayer_LastAimInfo
        );

    if (!isValidIOSPtr(aimPtr)) {
        ClearSilentState();
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);

        g_state.aimPtr = aimPtr;
        g_state.local  = local;
        g_state.target = target;

        g_hasData.store(
            true,
            std::memory_order_release
        );
    }

    g_cv.notify_one();
}

void ResetSilentAim() {
    ClearSilentState();
}
