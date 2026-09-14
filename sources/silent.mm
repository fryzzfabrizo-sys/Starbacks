// silent.mm
// Silent aim через ITransformNode головы (0x638).
// Prediction только по X/Z — без Y (иначе пули улетают вверх).

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
extern bool     aimsilent1;

// ─── Offsets (твои рабочие) ──────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

// ─── Prediction (только X/Z) ─────────────────────────────
static constexpr float kPredictTimeSec = 0.02f;   // 20мс мягкое упреждение
static constexpr float kMaxVelXZ       = 12.0f;   // м/с — только X/Z

// ─── Shared state ────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr     = 0;
static uint64_t          g_targetPawn = 0;
static uint64_t          g_lastMatch  = 0;

// Prediction state (только в воркере)
static uint64_t g_predPawn    = 0;
static Vector3  g_predLastPos = {0, 0, 0};
static std::chrono::steady_clock::time_point g_predLastTime;
static bool     g_predValid   = false;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};
    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};
    return getPositionExt(node);
}

// Prediction по X/Z. Y всегда оставляем как есть — иначе пули уходят вверх.
static Vector3 PredictHeadXZ(uint64_t pawn, const Vector3& cur) {
    Vector3 result = cur;

    if (pawn != g_predPawn) {
        g_predPawn     = pawn;
        g_predLastPos  = cur;
        g_predLastTime = std::chrono::steady_clock::now();
        g_predValid    = true;
        return result;
    }
    if (!g_predValid) {
        g_predLastPos  = cur;
        g_predLastTime = std::chrono::steady_clock::now();
        g_predValid    = true;
        return result;
    }

    auto now = std::chrono::steady_clock::now();
    float dt = std::chrono::duration<float>(now - g_predLastTime).count();
    if (dt < 0.002f || dt > 0.100f) {
        g_predLastPos  = cur;
        g_predLastTime = now;
        return result;
    }

    float vx = (cur.x - g_predLastPos.x) / dt;
    float vz = (cur.z - g_predLastPos.z) / dt;

    float vlenXZ = sqrtf(vx*vx + vz*vz);
    if (vlenXZ > 0.001f && vlenXZ < kMaxVelXZ) {
        result.x += vx * kPredictTimeSec;
        result.z += vz * kPredictTimeSec;
        // Y не трогаем — только обновляем семпл
    }

    g_predLastPos  = cur;
    g_predLastTime = now;
    return result;
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h, target;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h      = g_aimPtr;
            target = g_targetPawn;
        }
        if (!validPtr(h) || !validPtr(target)) { std::this_thread::yield(); continue; }

        Vector3 rawPos = HeadPos(target);
        if (!validVec(rawPos)) { std::this_thread::yield(); continue; }

        Vector3 tPos = PredictHeadXZ(target, rawPos);

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(h + kHit_RayDir, diff);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr     = 0;
    g_targetPawn = 0;
    g_predPawn   = 0;
    g_predValid  = false;
}

void RunSilentAim() {
    InitSilentAimThread();

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

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!validPtr(local) || !validPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (!validVec(tPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr     = aimPtr;
        g_targetPawn = target;
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенная запись в главном потоке — как в твоём рабочем silent 3.mm.
    // Это лечит «пропущенные пули» — даже если воркер не успел, запись уже есть.
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };
    WriteAddr<Vector3>(aimPtr + kHit_RayDir, diff);
}
