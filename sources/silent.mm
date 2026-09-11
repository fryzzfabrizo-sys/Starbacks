#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <thread>
#include <cstring>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

static constexpr float kHeadCenterY = 0.055f;
static constexpr uint64_t kTransitionCooldownMs = 500;

// Коэффициент упреждения (предикция для компенсации пинга и тикрейта при прыжках/беге)
static constexpr float kPredictionTime = 0.09f; // ~90ms в секундах

struct SharedData {
    uint64_t aimPtr;
    float hx, hy, hz;
    float lx, ly, lz;
};

static std::atomic<bool>       g_started{false};
static std::atomic<uint64_t>   g_transitionTick{0};
static uint64_t                g_lastMatch = 0;

static std::atomic<SharedData> g_sharedData{};
static std::atomic<bool>       g_hasData{false};

// Переменные для расчета скорости цели (предикция прыжков и движения)
static Vector3  g_lastTargetRawHead = {};
static uint64_t g_lastHeadTime      = 0;

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
//  WORKER — максимальная частота без мьютексов
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_relaxed);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }

        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        SharedData data = g_sharedData.load(std::memory_order_relaxed);
        if (!validPtr(data.aimPtr)) {
            std::this_thread::yield();
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(data.aimPtr + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f) {
            origin = {data.lx, data.ly, data.lz};
        }

        Vector3 dir = {
            data.hx - origin.x,
            data.hy - origin.y,
            data.hz - origin.z
        };

        WriteAddr<Vector3>(data.aimPtr + kHit_RayDir, dir);
        std::this_thread::yield();
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true)) {
        std::thread worker(SilentWorker);
        worker.detach();
    }
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_transitionTick.store(nowMs(), std::memory_order_release);
    g_lastMatch = 0;
    g_lastTargetRawHead = {};
    g_lastHeadTime = 0;
    g_sharedData.store(SharedData{}, std::memory_order_release);
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — расчет движения, предикция и обновление
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

    Vector3 rawHead = HeadPos(target);
    if (isZeroV3(rawHead)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t currentTime = nowMs();
    float dt = (g_lastHeadTime > 0) ? (currentTime - g_lastHeadTime) / 1000.0f : 0.016f;
    
    Vector3 velocity = {};
    if (dt > 0.001f && dt < 0.2f && !isZeroV3(g_lastTargetRawHead)) {
        velocity = {
            (rawHead.x - g_lastTargetRawHead.x) / dt,
            (rawHead.y - g_lastTargetRawHead.y) / dt,
            (rawHead.z - g_lastTargetRawHead.z) / dt
        };
    }

    g_lastTargetRawHead = rawHead;
    g_lastHeadTime = currentTime;

    // Применяем смещение центра головы
    rawHead.y += kHeadCenterY;

    // Предсказание позиции цели с учетом скорости (компенсация прыжков и рывков)
    Vector3 predictedHead = {
        rawHead.x + velocity.x * kPredictionTime,
        rawHead.y + velocity.y * kPredictionTime,
        rawHead.z + velocity.z * kPredictionTime
    };

    Vector3 lPos = HeadPos(local);

    SharedData newData;
    newData.aimPtr = aimPtr;
    newData.hx = predictedHead.x; 
    newData.hy = predictedHead.y; 
    newData.hz = predictedHead.z;
    newData.lx = lPos.x; 
    newData.ly = lPos.y; 
    newData.lz = lPos.z;

    g_sharedData.store(newData, std::memory_order_release);
    g_hasData.store(true, std::memory_order_release);
}
