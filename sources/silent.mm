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
static constexpr float kHeadCenterY = 0.055f;

// ── Лид по движущимся целям ──────────────────────────────
static constexpr float kLeadTime = 0.035f;
static constexpr float kMaxVel   = 30.0f;

// ── EMA скорости ─────────────────────────────────────────
static constexpr float kSmoothVelXZ = 0.80f;
static constexpr float kSmoothVelY  = 0.90f;

// ── Защита от краша при смене матча ──────────────────────
static constexpr uint64_t kTransitionCooldownMs = 1000;   // было 500

// ── Санити-проверка origin ───────────────────────────────
static constexpr float kMaxOriginDistSq = 500.0f * 500.0f;

// ═══════════════════════════════════════════════════════════════
//  Глобальное состояние
// ═══════════════════════════════════════════════════════════════

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<uint64_t> g_transitionTick{0};

static uint64_t g_aimPtr     = 0;
static uint64_t g_aimKlass   = 0;    // КЛЮЧЕВОЕ: klass pointer для проверки
static Vector3  g_predTarget = {};
static Vector3  g_localPos   = {};

static uint64_t g_lastMatch = 0;

static Vector3 s_prevTargetPos = {};
static bool    s_havePrevTarget = false;
static std::chrono::steady_clock::time_point s_prevTick;

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
//  WORKER — с проверкой klass pointer
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_acquire);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            continue;
        }

        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::microseconds(500));
            continue;
        }

        uint64_t h, expectedKlass;
        Vector3 pred, localPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h             = g_aimPtr;
            expectedKlass = g_aimKlass;
            pred          = g_predTarget;
            localPos      = g_localPos;
        }
        if (!validPtr(h) || expectedKlass == 0) {
            std::this_thread::yield();
            continue;
        }

        // ═══ ЗАЩИТА №1: KLASS POINTER ═══
        // Первые 8 байт любого IL2CPP-объекта — klass pointer.
        // Если память h переиспользована под другой объект — klass не совпадёт.
        uint64_t curKlass = ReadAddr<uint64_t>(h + 0);
        if (curKlass != expectedKlass) {
            std::this_thread::yield();
            continue;
        }

        // Read origin
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = localPos;

        // ═══ ЗАЩИТА №2: SANITY CHECK ═══
        // Origin должен быть рядом с локальным игроком (в радиусе 500м).
        // Если далеко — память повреждена, не пишем.
        float dxo = origin.x - localPos.x;
        float dyo = origin.y - localPos.y;
        float dzo = origin.z - localPos.z;
        float originDistSq = dxo*dxo + dyo*dyo + dzo*dzo;
        if (originDistSq > kMaxOriginDistSq) continue;

        Vector3 dir = { pred.x - origin.x, pred.y - origin.y, pred.z - origin.z };
        WriteAddr<Vector3>(h + kHit_RayDir, dir);

        std::this_thread::yield();
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
    s_havePrevTarget = false;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        g_aimKlass = 0;
        g_predTarget = {};
        g_localPos = {};
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
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
        s_prevTick = std::chrono::steady_clock::now();
        return;
    }

    auto now = std::chrono::steady_clock::now();
    float dt = std::chrono::duration<float>(now - s_prevTick).count();
    s_prevTick = now;
    if (dt <= 0.001f || dt > 0.25f) dt = 0.016f;

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        return;
    }

    // ─── Читаем klass pointer HitObjectInfo ──────────────
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

    // ─── Скорость цели ──────────────────────────────────
    Vector3 rawVel = {0, 0, 0};
    if (s_havePrevTarget) {
        rawVel = {
            (head.x - s_prevTargetPos.x) / dt,
            (head.y - s_prevTargetPos.y) / dt,
            (head.z - s_prevTargetPos.z) / dt
        };
        float lenSq = rawVel.x*rawVel.x + rawVel.y*rawVel.y + rawVel.z*rawVel.z;
        if (lenSq > kMaxVel * kMaxVel) {
            float invLen = kMaxVel / std::sqrt(lenSq);
            rawVel.x *= invLen; rawVel.y *= invLen; rawVel.z *= invLen;
        }
    }
    s_prevTargetPos = head;
    s_havePrevTarget = true;

    // ─── EMA ────────────────────────────────────────────
    static Vector3 s_vel = {0, 0, 0};
    s_vel.x = s_vel.x * (1.0f - kSmoothVelXZ) + rawVel.x * kSmoothVelXZ;
    s_vel.z = s_vel.z * (1.0f - kSmoothVelXZ) + rawVel.z * kSmoothVelXZ;
    s_vel.y = s_vel.y * (1.0f - kSmoothVelY)  + rawVel.y * kSmoothVelY;

    // ─── Предвычисление цели ────────────────────────────
    Vector3 pred = {
        head.x + s_vel.x * kLeadTime,
        head.y + kHeadCenterY + s_vel.y * kLeadTime,
        head.z + s_vel.z * kLeadTime
    };

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr     = aimPtr;
        g_aimKlass   = klass;
        g_predTarget = pred;
        g_localPos   = lPos;
    }
    g_hasData.store(true, std::memory_order_release);
}
