#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <mutex>
#include <thread>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

// ТОЧНАЯ КАЛИБРОВКА:
// kHeadCenterX: отрицательное значение сдвигает точку влево (убирает уход пуль вправо)
// kHeadCenterY: поднимает точку выше (чтобы при прыжках и падениях не било в шею)
static constexpr float kHeadCenterX = -0.02f; 
static constexpr float kHeadCenterY =  0.12f; 

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t g_aimPtr   = 0;
static uint64_t g_aimKlass = 0;
static Vector3  g_headPos  = {};
static Vector3  g_localPos = {};

static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

// Быстрая нормализация вектора
static inline Vector3 NormalizeVector(const Vector3& v) {
    float len = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (len < 1e-5f) return {0.0f, 0.0f, 1.0f};
    return {v.x / len, v.y / len, v.z / len};
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return validPtr(t) ? getPositionExt(t) : Vector3{};
}

// Расчет траектории с коррекцией под прыжки и маневры
static inline void ApplySilentWrite(uint64_t h, uint64_t klass, const Vector3& head, const Vector3& lPos) {
    if (!validPtr(h)) return;

    uint64_t curKlass = ReadAddr<uint64_t>(h + 0);
    if (curKlass != klass || !validPtr(curKlass)) return;

    Vector3 origin = lPos;
    if (isZeroV3(origin)) {
        origin = ReadAddr<Vector3>(h + kHit_StartPos);
    }

    Vector3 diff = {
        head.x - origin.x,
        head.y - origin.y,
        head.z - origin.z
    };

    Vector3 dir = NormalizeVector(diff);
    WriteAddr<Vector3>(h + kHit_RayDir, dir);
}

// ═══════════════════════════════════════════════════════════════
//  WORKER — максимальная частота опроса без задержек
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (g_started.load(std::memory_order_relaxed)) {
        if (!g_hasData.load(std::memory_order_relaxed) || !aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h     = 0;
        uint64_t klass = 0;
        Vector3 headPos, localPos;
        
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            klass    = g_aimKlass;
            headPos  = g_headPos;
            localPos = g_localPos;
        }

        if (!validPtr(h)) {
            std::this_thread::yield();
            continue;
        }

        ApplySilentWrite(h, klass, headPos, localPos);
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
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = 0;
        g_aimKlass = 0;
        g_headPos  = {};
        g_localPos = {};
    }
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

    Vector3 head = HeadPos(target);
    if (isZeroV3(head)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }
    
    // Возвращаем и усиливаем компенсацию:
    // kHeadCenterX уводит пули обратно влево (компенсируя правый сдвиг)
    // kHeadCenterY задирает точку выше, компенсируя просадку хитбокса при прыжках
    head.x += kHeadCenterX;
    head.y += kHeadCenterY;

    Vector3 lPos = {}; 

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = aimPtr;
        g_aimKlass = klass;
        g_headPos  = head;
        g_localPos = lPos;
    }
    g_hasData.store(true, std::memory_order_release);

    ApplySilentWrite(aimPtr, klass, head, lPos);
}
