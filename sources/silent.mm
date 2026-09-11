#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <thread>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

static std::atomic<bool>     g_started{false};
static std::atomic<bool>     g_hasData{false};

// Атомарное хранение указателей и векторов без тяжелых мьютексов
static std::atomic<uint64_t> g_atomAimPtr{0};
static std::atomic<uint64_t> g_atomAimKlass{0};

static std::atomic<float>    g_atomTargetX{0.0f};
static std::atomic<float>    g_atomTargetY{0.0f};
static std::atomic<float>    g_atomTargetZ{0.0f};

static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static inline Vector3 NormalizeVector(const Vector3& v) {
    float len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len < 1e-5f) return {0.0f, 0.0f, 1.0f};
    return {v.x / len, v.y / len, v.z / len};
}

static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    
    uint64_t headNode = ReadAddr<uint64_t>(pawn + kHeadNode);
    Vector3 pos = {};
    if (validPtr(headNode)) {
        uint64_t transformNode = ReadAddr<uint64_t>(headNode + kBodyPartTransNode);
        if (validPtr(transformNode)) {
            pos = getPositionExt(transformNode);
        }
    }
    
    if (isZeroV3(pos)) {
        uint64_t fallbackHead = getHead(pawn);
        if (validPtr(fallbackHead)) {
            pos = getPositionExt(fallbackHead);
        }
    }
    
    if (isZeroV3(pos)) return {};

    uint64_t physCCT = ReadAddr<uint64_t>(pawn + kPhysCCT);
    if (validPtr(physCCT)) {
        Vector3 velocity = ReadAddr<Vector3>(physCCT + kPhysCCT_Velocity);
        pos.x += velocity.x * 0.07f;
        pos.y += velocity.y * 0.07f;
        pos.z += velocity.z * 0.07f;
    }

    pos.y += 0.09f; 
    return pos;
}

static inline void ApplySilentWrite(uint64_t h, uint64_t klass, const Vector3& targetPos) {
    if (!validPtr(h)) return;

    uint64_t curKlass = ReadAddr<uint64_t>(h + 0);
    if (curKlass != klass || !validPtr(curKlass)) return;

    Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
    Vector3 diff = {
        targetPos.x - origin.x,
        targetPos.y - origin.y,
        targetPos.z - origin.z
    };

    Vector3 dir = NormalizeVector(diff);
    WriteAddr<Vector3>(h + kHit_RayDir, dir);
}

static void SilentWorker() {
    while (g_started.load(std::memory_order_relaxed)) {
        if (!g_hasData.load(std::memory_order_relaxed) || !aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h     = g_atomAimPtr.load(std::memory_order_relaxed);
        uint64_t klass = g_atomAimKlass.load(std::memory_order_relaxed);
        
        Vector3 tPos = {
            g_atomTargetX.load(std::memory_order_relaxed),
            g_atomTargetY.load(std::memory_order_relaxed),
            g_atomTargetZ.load(std::memory_order_relaxed)
        };

        if (!validPtr(h)) {
            std::this_thread::yield();
            continue;
        }

        ApplySilentWrite(h, klass, tPos);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastMatch = 0;
    g_atomAimPtr.store(0, std::memory_order_relaxed);
    g_atomAimKlass.store(0, std::memory_order_relaxed);
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
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

    uint64_t klass = ReadAddr<uint64_t>(aimPtr + 0);
    if (!validPtr(klass)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 targetPos = GetHeadPosition(target);
    if (isZeroV3(targetPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Мгновенная атомарная запись без блокировки потоков
    g_atomAimPtr.store(aimPtr, std::memory_order_relaxed);
    g_atomAimKlass.store(klass, std::memory_order_relaxed);
    g_atomTargetX.store(targetPos.x, std::memory_order_relaxed);
    g_atomTargetY.store(targetPos.y, std::memory_order_relaxed);
    g_atomTargetZ.store(targetPos.z, std::memory_order_relaxed);

    g_hasData.store(true, std::memory_order_release);

    ApplySilentWrite(aimPtr, klass, targetPos);
}
