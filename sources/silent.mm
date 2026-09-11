#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

// ── Захват головы ─────────────────────────────────────────
// Смещение от bone_Head (основание черепа) в центр головы.
static constexpr float kHeadCenterY = 0.055f;

// ── Защита от краша при смене матча ──────────────────────
static constexpr uint64_t kTransitionCooldownMs = 500;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<uint64_t> g_transitionTick{0};

static uint64_t g_aimPtr   = 0;
static Vector3  g_headPos  = {};
static Vector3  g_localPos = {};

static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}
static inline uint64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  WORKER — максимальная частота, без sleep
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_acquire);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3 headPos, localPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            headPos  = g_headPos;
            localPos = g_localPos;
        }
        if (!validPtr(h)) continue;

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = localPos;

        // RAW вектор от origin к центру головы. Без лида.
        Vector3 dir = {
            headPos.x - origin.x,
            headPos.y - origin.y,
            headPos.z - origin.z
        };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_transitionTick.store(nowMs(), std::memory_order_release);
    g_lastMatch = 0;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = 0;
        g_headPos  = {};
        g_localPos = {};
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — обновляет позицию головы, пингует
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
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

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 head = HeadPos(target);
    if (isZeroV3(head)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Смещение к центру черепа
    head.y += kHeadCenterY;

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = aimPtr;
        g_headPos  = head;
        g_localPos = lPos;
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенный пинг — прямо в голову без лида
    {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        Vector3 dir = {
            head.x - origin.x,
            head.y - origin.y,
            head.z - origin.z
        };
        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
    }
}
