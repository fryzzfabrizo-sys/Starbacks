#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"

#include <cmath>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <queue>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// OB54 iOS 64-bit
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kPlayer_IsAiming    = 0x4A0;  // больше не используется
static constexpr uint64_t kHit_RayDir        = 0x40;
static constexpr uint64_t kHit_StartPos      = 0x4C;
static constexpr uint64_t kWpn_CostAmmo      = 0x7B8;


// ============================================================
// STATE
// ============================================================

struct SilentState {
    uint64_t match  = 0;
    uint64_t aimPtr = 0;
    uint64_t local  = 0;
    uint64_t target = 0;
};

static std::mutex              g_lock;
static std::condition_variable g_cv;

static std::queue<SilentState> g_queue;          // очередь состояний
static std::atomic<bool>       g_started{false};
static std::atomic<bool>       g_stop{false};

static std::thread g_worker;


// ============================================================
// VALIDATION
// ============================================================

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


// ============================================================
// HEAD POSITION
// ============================================================

static Vector3 HeadPos(uint64_t pawn) {

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
// CLEAR STATE
// ============================================================

static void ClearSilentState() {

    {
        std::lock_guard<std::mutex> lk(g_lock);
        while (!g_queue.empty()) g_queue.pop();
    }

    g_cv.notify_all();
}


// ============================================================
// MATCH VALIDATION
// ============================================================

static inline bool IsSameMatch(uint64_t match) {

    uint64_t current = cachedMatch;

    if (!isVaildPtr(current))
        return false;

    if (!isVaildPtr(match))
        return false;

    return current == match;
}


// ============================================================
// WORKER
// ============================================================

static void SilentWorker() {

    while (!g_stop.load(std::memory_order_acquire)) {

        SilentState state;

        // ----------------------------------------------------
        // Ждём, пока очередь не станет непустой или не придёт стоп
        // ----------------------------------------------------

        {
            std::unique_lock<std::mutex> lk(g_lock);

            g_cv.wait(lk, [] {
                return
                    g_stop.load(std::memory_order_acquire) ||
                    !g_queue.empty();
            });

            if (g_stop.load(std::memory_order_acquire))
                break;

            state = g_queue.front();
            g_queue.pop();
        }


        // ----------------------------------------------------
        // MATCH CHECK #1
        // ----------------------------------------------------

        if (!IsSameMatch(state.match)) {
            continue;
        }


        // ----------------------------------------------------
        // POINTER CHECK
        // ----------------------------------------------------

        if (!isValidIOSPtr(state.aimPtr) ||
            !isVaildPtr(state.local) ||
            !isVaildPtr(state.target)) {

            continue;
        }


        // ----------------------------------------------------
        // TARGET POSITION
        // ----------------------------------------------------

        Vector3 tPos = HeadPos(state.target);

        if (!isValidVector(tPos) ||
            isZeroVector(tPos)) {
            continue;
        }

        tPos.y += 0.05f;


        // ----------------------------------------------------
        // MATCH CHECK #2
        // ----------------------------------------------------

        if (!IsSameMatch(state.match)) {
            continue;
        }


        // ----------------------------------------------------
        // ORIGIN
        // ----------------------------------------------------

        Vector3 origin =
            ReadAddr<Vector3>(
                state.aimPtr + kHit_StartPos
            );

        if (!isValidVector(origin))
            continue;


        if (isZeroVector(origin)) {

            origin = HeadPos(state.local);

            if (!isValidVector(origin) ||
                isZeroVector(origin)) {
                continue;
            }
        }


        // ----------------------------------------------------
        // MATCH CHECK #3
        // ----------------------------------------------------

        if (!IsSameMatch(state.match)) {
            continue;
        }


        // ----------------------------------------------------
        // DIRECTION
        // ----------------------------------------------------

        Vector3 dir{
            tPos.x - origin.x,
            tPos.y - origin.y,
            tPos.z - origin.z
        };


        if (!isValidVector(dir) ||
            isZeroVector(dir)) {
            continue;
        }


        // ----------------------------------------------------
        // FINAL MATCH CHECK
        // ----------------------------------------------------

        if (!IsSameMatch(state.match)) {
            continue;
        }


        // ----------------------------------------------------
        // WRITE
        // ----------------------------------------------------

        WriteAddr<Vector3>(
            state.aimPtr + kHit_RayDir,
            dir
        );
    }
}


// ============================================================
// INIT
// ============================================================

void InitSilentAimThread() {

    bool expected = false;

    if (!g_started.compare_exchange_strong(
            expected,
            true,
            std::memory_order_acq_rel)) {
        return;
    }

    g_stop.store(
        false,
        std::memory_order_release
    );

    g_worker = std::thread([] {
        SilentWorker();
    });
}


// ============================================================
// SHUTDOWN
// ============================================================

void ShutdownSilentAimThread() {

    bool expected = true;

    if (!g_started.compare_exchange_strong(
            expected,
            false,
            std::memory_order_acq_rel)) {
        return;
    }

    g_stop.store(
        true,
        std::memory_order_release
    );

    g_cv.notify_all();

    if (g_worker.joinable())
        g_worker.join();

    {
        std::lock_guard<std::mutex> lk(g_lock);
        while (!g_queue.empty()) g_queue.pop();
    }

    g_stop.store(
        false,
        std::memory_order_release
    );
}


// ============================================================
// RUN
// ============================================================

void RunSilentAim() {

    InitSilentAimThread();


    // --------------------------------------------------------
    // CURRENT MATCH
    // --------------------------------------------------------

    uint64_t match = cachedMatch;

    if (!aimsilent1 ||
        !isVaildPtr(match)) {

        ClearSilentState();
        return;
    }


    // --------------------------------------------------------
    // LOCAL
    // --------------------------------------------------------

    uint64_t local =
        getLocalPlayer(match);

    if (!isVaildPtr(local)) {

        ClearSilentState();
        return;
    }


    // --------------------------------------------------------
    // TARGET
    // --------------------------------------------------------

    uint64_t target =
        g_SilentBestTarget;

    if (!isVaildPtr(target)) {

        ClearSilentState();
        return;
    }


    // --------------------------------------------------------
    // VERIFY MATCH AGAIN
    // --------------------------------------------------------

    if (!IsSameMatch(match)) {

        ClearSilentState();
        return;
    }


    // --------------------------------------------------------
    // WEAPON (опционально, но оставлено для безопасности)
    // --------------------------------------------------------

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


    // --------------------------------------------------------
    // AIM INFO
    // --------------------------------------------------------

    uint64_t aimPtr =
        ReadAddr<uint64_t>(
            local + kPlayer_LastAimInfo
        );

    if (!isValidIOSPtr(aimPtr)) {

        ClearSilentState();
        return;
    }


    // --------------------------------------------------------
    // FINAL CHECK BEFORE PUBLISH
    // --------------------------------------------------------

    if (!IsSameMatch(match)) {

        ClearSilentState();
        return;
    }


    // --------------------------------------------------------
    // ДОБАВЛЯЕМ СОСТОЯНИЕ В ОЧЕРЕДЬ
    // --------------------------------------------------------

    {
        std::lock_guard<std::mutex> lk(g_lock);

        SilentState st;
        st.match  = match;
        st.aimPtr = aimPtr;
        st.local  = local;
        st.target = target;

        g_queue.push(st);
    }

    g_cv.notify_one();
}


// ============================================================
// RESET
// ============================================================

void ResetSilentAim() {

    ClearSilentState();
}
