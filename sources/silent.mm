// SilentAim.mm
// Silent aim через ITransformNode головы (0x638) + запись TargetPos (0x28) и RayDir (0x40) с упреждением
// + диагностика Hit_HeadCollider (0x20)

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Offsets ────────────────────────────────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;   // LastAimInfo_Ptr
static constexpr uint64_t kHit_RayDir         = 0x40;    // Vector3 RayDir
static constexpr uint64_t kHit_StartPos       = 0x4C;    // Vector3 StartPos
static constexpr uint64_t kHit_TargetPos      = 0x28;    // Vector3 TargetPos

// Диагностика / эксперименты
static constexpr uint64_t kHit_HeadCollider   = 0x20;    // uint64 HeadCollider (в HitInfo)
static constexpr uint64_t kHit_SpecialHitType = 0x80;    // int SpecialHitType

static constexpr uint64_t kPlayer_HeadNode    = 0x638;   // ITransformNode Head
static constexpr uint64_t kBodyPart_TransNode = 0x10;    // ITransformNode -> Transform

// ─── Debug (читаем, не пишем) ───────────────────────────────────────
static std::atomic<uint64_t> g_dbgHeadCollider{0};
static std::atomic<int>      g_dbgSpecialHit{0};

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

static Vector3           g_lastEnemyPos = {};
static auto              g_lastTime     = std::chrono::high_resolution_clock::now();
static uint64_t          g_lastTarget   = 0;

// ─── Helpers ────────────────────────────────────────────────────────
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

// ─── Silent Worker ──────────────────────────────────────────────────
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
        }

        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };

        WriteAddr<Vector3>(h + kHit_RayDir, diff);
        WriteAddr<Vector3>(h + kHit_TargetPos, tPos);

        // ─── Диагностика (только чтение) ───────────────────────────
        uint64_t hc = ReadAddr<uint64_t>(h + kHit_HeadCollider);
        int      st = ReadAddr<int>(h + kHit_SpecialHitType);
        g_dbgHeadCollider.store(hc, std::memory_order_relaxed);
        g_dbgSpecialHit.store(st,   std::memory_order_relaxed);

        // Раскомментируй, чтобы логировать в консоль:
        // NSLOG(@"[SA] HC=0x%llx  SHT=%d", hc, st);
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
    g_aimPtr       = 0;
    g_tPos         = {};
    g_lastEnemyPos = {};
    g_lastTarget   = 0;
}

// ─── Main ───────────────────────────────────────────────────────────
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

    if (target != g_lastTarget) {
        g_lastEnemyPos = tPos;
        g_lastTarget   = target;
        g_lastTime     = std::chrono::high_resolution_clock::now();
    }

    auto now = std::chrono::high_resolution_clock::now();
    float dt = std::chrono::duration<float>(now - g_lastTime).count();

    Vector3 velocity = {};
    if (dt > 0.0001f && dt < 0.1f) {
        velocity.x = (tPos.x - g_lastEnemyPos.x) / dt;
        velocity.y = (tPos.y - g_lastEnemyPos.y) / dt;
        velocity.z = (tPos.z - g_lastEnemyPos.z) / dt;
    }

    g_lastEnemyPos = tPos;
    g_lastTime     = now;

    float predictionTime = 0.12f;

    Vector3 predictedPos = {
        tPos.x + velocity.x * predictionTime,
        tPos.y + velocity.y * predictionTime,
        tPos.z + velocity.z * predictionTime
    };

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = predictedPos;
    }
    g_hasData.store(true, std::memory_order_release);

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = { predictedPos.x - origin.x,
                       predictedPos.y - origin.y,
                       predictedPos.z - origin.z };

    WriteAddr<Vector3>(aimPtr + kHit_RayDir, diff);
    WriteAddr<Vector3>(aimPtr + kHit_TargetPos, predictedPos);

    // ─── Диагностика в кадре ───────────────────────────────────────
    uint64_t hc = ReadAddr<uint64_t>(aimPtr + kHit_HeadCollider);
    int      st = ReadAddr<int>(aimPtr + kHit_SpecialHitType);
    g_dbgHeadCollider.store(hc, std::memory_order_relaxed);
    g_dbgSpecialHit.store(st,   std::memory_order_relaxed);
}
