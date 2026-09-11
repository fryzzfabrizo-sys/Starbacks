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
static constexpr uint64_t kTransitionCooldownMs = 300; // Снижено для мгновенного отклика при смене цели

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
//  WORKER — максимальная частота с предиктивной нормализацией
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_relaxed);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
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

        // Вычисляем вектор направления с учетом баллистического центра головы
        Vector3 dir = {
            data.hx - origin.x,
            data.hy - origin.y,
            data.hz - origin.z
        };

        // Агрессивная нормализация с обработкой микро-флуктуаций
        float lengthSq = dir.x * dir.x + dir.y * dir.y + dir.z * dir.z;
        if (lengthSq > 0.000001f) {
            float invLength = 1.0f / std::sqrt(lengthSq);
            dir.x *= invLength;
            dir.y *= invLength;
            dir.z *= invLength;
            
            // Принудительная запись без пропусков кадра для абсолютного перенаправления
            WriteAddr<Vector3>(data.aimPtr + kHit_RayDir, dir);
        }

        // Убран yield для максимальной частоты обновления шины памяти
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
    g_sharedData.store(SharedData{}, std::memory_order_release);
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — обновление данных из основного потока
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

    head.y += kHeadCenterY;
    Vector3 lPos = HeadPos(local);

    SharedData newData;
    newData.aimPtr = aimPtr;
    newData.hx = head.x; newData.hy = head.y; newData.hz = head.z;
    newData.lx = lPos.x; newData.ly = lPos.y; newData.lz = lPos.z;

    g_sharedData.store(newData, std::memory_order_release);
    g_hasData.store(true, std::memory_order_release);
}
