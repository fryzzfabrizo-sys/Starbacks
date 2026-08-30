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
static constexpr uint64_t kPlayer_IsAiming    = 0x4A0;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;


// ============================================================
// STATE
// ============================================================

struct SilentState {
    uint64_t match  = 0;
    uint64_t aimPtr = 0;
    uint64_t local  = 0;
    uint64_t target = 0;
    uint64_t serial = 0;
};

static std::mutex g_lock;

static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<bool> g_stop{false};

static SilentState g_state{};
static uint64_t g_serial = 0;

static std::thread g_worker;


// ============================================================
// VALIDATION
// ============================================================

static inline bool isValidIOSPtr(uint64_t p)
{
    return p >= 0x100000000ULL &&
           p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool isValidVector(const Vector3& v)
{
    return std::isfinite(v.x) &&
           std::isfinite(v.y) &&
           std::isfinite(v.z);
}

static inline bool isZeroVector(const Vector3& v)
{
    return v.x == 0.0f &&
           v.y == 0.0f &&
           v.z == 0.0f;
}


// ============================================================
// HEAD
// ============================================================

static Vector3 HeadPos(uint64_t pawn)
{
    if (!isVaildPtr(pawn))
        return {};

    uint64_t head = getHead(pawn);

    if (!isVaildPtr(head))
        return {};

    Vector3 pos = getPositionExt(head);

    if (!isValidVector(pos))
        return {};

    return pos;
}


// ============================================================
// CLEAR
// ============================================================

static void ClearSilentState()
{
    std::lock_guard<std::mutex> lock(g_lock);

    ++g_serial;

    g_state.match  = 0;
    g_state.aimPtr = 0;
    g_state.local  = 0;
    g_state.target = 0;
    g_state.serial = g_serial;

    g_hasData.store(
        false,
        std::memory_order_release
    );
}


// ============================================================
// PUBLISH
// ============================================================

static void PublishSilentState(
    uint64_t match,
    uint64_t aimPtr,
    uint64_t local,
    uint64_t target)
{
    std::lock_guard<std::mutex> lock(g_lock);

    ++g_serial;

    g_state.match  = match;
    g_state.aimPtr = aimPtr;
    g_state.local  = local;
    g_state.target = target;
    g_state.serial  = g_serial;

    g_hasData.store(
        true,
        std::memory_order_release
    );
}


// ============================================================
// SNAPSHOT VALIDATION
// ============================================================

static bool IsSnapshotStillValid(
    const SilentState& snapshot)
{
    if (!g_hasData.load(std::memory_order_acquire))
        return false;

    uint64_t currentMatch = cachedMatch;

    if (!isVaildPtr(currentMatch))
        return false;

    if (currentMatch != snapshot.match)
        return false;

    std::lock_guard<std::mutex> lock(g_lock);

    if (!g_hasData.load(std::memory_order_relaxed))
        return false;

    if (g_state.serial != snapshot.serial)
        return false;

    if (g_state.match != snapshot.match)
        return false;

    if (g_state.aimPtr != snapshot.aimPtr)
        return false;

    if (g_state.local != snapshot.local)
        return false;

    if (g_state.target != snapshot.target)
        return false;

    return true;
}


// ============================================================
// WORKER
// ============================================================

static void SilentWorker()
{
    while (!g_stop.load(std::memory_order_acquire))
    {
        if (!g_hasData.load(std::memory_order_acquire))
        {
            std::this_thread::yield();
            continue;
        }

        SilentState snapshot;

        {
            std::lock_guard<std::mutex> lock(g_lock);

            if (!g_hasData.load(std::memory_order_relaxed))
                continue;

            snapshot = g_state;
        }

        // ----------------------------------------------------
        // Проверка snapshot
        // ----------------------------------------------------

        if (!isValidIOSPtr(snapshot.match) ||
            !isValidIOSPtr(snapshot.aimPtr) ||
            !isVaildPtr(snapshot.local) ||
            !isVaildPtr(snapshot.target))
        {
            continue;
        }

        // ----------------------------------------------------
        // Проверка текущего матча
        // ----------------------------------------------------

        if (cachedMatch != snapshot.match)
        {
            ClearSilentState();
            continue;
        }

        // ----------------------------------------------------
        // Target
        // ----------------------------------------------------

        Vector3 targetPos = HeadPos(snapshot.target);

        if (!isValidVector(targetPos) ||
            isZeroVector(targetPos))
        {
            continue;
        }

        targetPos.y += 0.05f;

        // ----------------------------------------------------
        // Проверяем snapshot после чтения target
        // ----------------------------------------------------

        if (!IsSnapshotStillValid(snapshot))
            continue;

        // ----------------------------------------------------
        // Origin
        // ----------------------------------------------------

        Vector3 origin =
            ReadAddr<Vector3>(
                snapshot.aimPtr + kHit_StartPos
            );

        if (!isValidVector(origin))
            continue;

        if (isZeroVector(origin))
        {
            origin = HeadPos(snapshot.local);

            if (!isValidVector(origin) ||
                isZeroVector(origin))
            {
                continue;
            }
        }

        // ----------------------------------------------------
        // Проверяем snapshot после чтения origin
        // ----------------------------------------------------

        if (!IsSnapshotStillValid(snapshot))
            continue;

        // ----------------------------------------------------
        // RAW direction
        // ----------------------------------------------------

        Vector3 direction{
            targetPos.x - origin.x,
            targetPos.y - origin.y,
            targetPos.z - origin.z
        };

        if (!isValidVector(direction) ||
            isZeroVector(direction))
        {
            continue;
        }

        // ----------------------------------------------------
        // Финальная проверка непосредственно перед записью
        // ----------------------------------------------------

        if (!IsSnapshotStillValid(snapshot))
            continue;

        // ----------------------------------------------------
        // WRITE
        // ----------------------------------------------------

        WriteAddr<Vector3>(
            snapshot.aimPtr + kHit_RayDir,
            direction
        );
    }
}


// ============================================================
// INIT
// ============================================================

void InitSilentAimThread()
{
    bool expected = false;

    if (!g_started.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acq_rel))
    {
        return;
    }

    g_stop.store(
        false,
        std::memory_order_release
    );

    g_worker = std::thread(
        SilentWorker
    );
}


// ============================================================
// SHUTDOWN
// ============================================================

void ShutdownSilentAimThread()
{
    bool expected = true;

    if (!g_started.compare_exchange_strong(
            expected,
            false,
            std::memory_order_acq_rel))
    {
        return;
    }

    g_stop.store(
        true,
        std::memory_order_release
    );

    g_hasData.store(
        false,
        std::memory_order_release
    );

    if (g_worker.joinable())
        g_worker.join();

    {
        std::lock_guard<std::mutex> lock(g_lock);

        ++g_serial;

        g_state = {};
        g_state.serial = g_serial;
    }

    g_stop.store(
        false,
        std::memory_order_release
    );
}


// ============================================================
// RUN
// ============================================================

void RunSilentAim()
{
    InitSilentAimThread();

    // --------------------------------------------------------
    // Match
    // --------------------------------------------------------

    uint64_t match = cachedMatch;

    if (!aimsilent1 ||
        !isVaildPtr(match))
    {
        ClearSilentState();
        return;
    }

    // --------------------------------------------------------
    // Local
    // --------------------------------------------------------

    uint64_t local =
        getLocalPlayer(match);

    if (!isVaildPtr(local))
    {
        ClearSilentState();
        return;
    }

    // --------------------------------------------------------
    // Target
    // --------------------------------------------------------

    uint64_t target =
        g_SilentBestTarget;

    if (!isVaildPtr(target))
    {
        ClearSilentState();
        return;
    }

    // --------------------------------------------------------
    // Match повторно
    // --------------------------------------------------------

    if (cachedMatch != match)
    {
        ClearSilentState();
        return;
    }

    // --------------------------------------------------------
    // Weapon
    // --------------------------------------------------------

    uint64_t weapon =
        WeaponOnHand(local);

    if (isVaildPtr(weapon))
    {
        bool costAmmo =
            ReadAddr<bool>(
                weapon + kWpn_CostAmmo
            );

        if (!costAmmo)
        {
            ClearSilentState();
            return;
        }
    }

    // --------------------------------------------------------
    // Aiming
    // --------------------------------------------------------

    bool isAiming =
        ReadAddr<bool>(
            local + kPlayer_IsAiming
        );

    if (!isAiming)
    {
        ClearSilentState();
        return;
    }

    // --------------------------------------------------------
    // Current Aim Object
    // --------------------------------------------------------

    uint64_t aimPtr =
        ReadAddr<uint64_t>(
            local + kPlayer_LastAimInfo
        );

    if (!isValidIOSPtr(aimPtr))
    {
        ClearSilentState();
        return;
    }

    // --------------------------------------------------------
    // Последняя проверка перед публикацией
    // --------------------------------------------------------

    if (cachedMatch != match)
    {
        ClearSilentState();
        return;
    }

    // --------------------------------------------------------
    // Публикуем ВСЁ одним snapshot
    // --------------------------------------------------------

    PublishSilentState(
        match,
        aimPtr,
        local,
        target
    );
}


// ============================================================
// RESET
// ============================================================

void ResetSilentAim()
{
    ClearSilentState();
}
