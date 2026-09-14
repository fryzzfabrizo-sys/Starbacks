// silent.mm
// Silent aim через ITransformNode головы (0x638, подтверждено дампом).
// Всегда в центр головы, с prediction для движущихся/прыгающих врагов.

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include <thread>
#include <unordered_map>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Offsets (голова подтверждена дампом 2026-09-14) ────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;   // HEAD (Y +1.28м от root)
static constexpr uint64_t kBodyPart_TransNode = 0x10;    // → getPositionExt = позиция кости

// ─── Параметры ──────────────────────────────────────────
static constexpr float kPredictTimeSec  = 0.06f;   // 60мс — окно предсказания
static constexpr float kHeadCenterY     = 0.12f;   // +12см к центру черепа
static constexpr float kMaxVel          = 40.0f;   // sanity: телепорт-защита
static constexpr int   kWorkerTickMs    = 2;
static constexpr int   kMaxSamples      = 64;

// ─── State ──────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr     = 0;
static uint64_t          g_targetPawn = 0;
static uint64_t          g_lastMatch  = 0;

struct HeadSample {
    Vector3 pos;
    std::chrono::steady_clock::time_point time;
    bool valid = false;
};

static std::unordered_map<uint64_t, HeadSample> g_headSamples;
static std::mutex                                g_samplesLock;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}

// ─── Голова с prediction ────────────────────────────────
static Vector3 HeadPosPredicted(uint64_t pawn) {
    if (!validPtr(pawn)) return {};

    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};

    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};

    Vector3 cur = getPositionExt(node);
    if (!validVec(cur)) return {};

    auto now = std::chrono::steady_clock::now();

    std::lock_guard<std::mutex> lk(g_samplesLock);
    HeadSample& sample = g_headSamples[pawn];

    Vector3 result = cur;

    if (sample.valid) {
        float dt = std::chrono::duration<float>(now - sample.time).count();
        if (dt > 0.005f && dt < 0.30f) {
            Vector3 vel = {
                (cur.x - sample.pos.x) / dt,
                (cur.y - sample.pos.y) / dt,
                (cur.z - sample.pos.z) / dt
            };
            float velLen = sqrtf(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z);
            if (velLen < kMaxVel) {
                result.x += vel.x * kPredictTimeSec;
                result.y += vel.y * kPredictTimeSec;
                result.z += vel.z * kPredictTimeSec;
            }
        }
    }

    sample.pos   = cur;
    sample.time  = now;
    sample.valid = true;

    result.y += kHeadCenterY;   // центр черепа
    return result;
}

// ─── Воркер ─────────────────────────────────────────────
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(kWorkerTickMs));
            continue;
        }

        uint64_t aimPtr;
        uint64_t target;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            aimPtr = g_aimPtr;
            target = g_targetPawn;
        }

        if (!validPtr(aimPtr) || !validPtr(target)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(kWorkerTickMs));
            continue;
        }

        Vector3 tPos = HeadPosPredicted(target);
        if (!validVec(tPos)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(kWorkerTickMs));
            continue;
        }

        // origin перечитывается каждый тик — точнее при движении камеры
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        Vector3 diff = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };

        // Защита от мусора — если diff слишком мал или слишком велик, не пишем
        float dlen = sqrtf(diff.x*diff.x + diff.y*diff.y + diff.z*diff.z);
        if (dlen > 0.01f && dlen < 500.0f) {
            WriteAddr<Vector3>(aimPtr + kHit_RayDir, diff);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(kWorkerTickMs));
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr     = 0;
        g_targetPawn = 0;
    }
    {
        std::lock_guard<std::mutex> lk(g_samplesLock);
        g_headSamples.clear();
    }
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

    // Ограничение размера семплов
    {
        std::lock_guard<std::mutex> lk(g_samplesLock);
        if (g_headSamples.size() > kMaxSamples)
            g_headSamples.clear();
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr     = aimPtr;
        g_targetPawn = target;
    }
    g_hasData.store(true, std::memory_order_release);
}
