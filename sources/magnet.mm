// magnet.mm
// Aim Magnet — плавное притяжение головы к лучу камеры, синхронно с игрой (60 Hz)

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimMagnet;

// ─── Transform write offsets ────────────────────────────────────────
static constexpr uint64_t kT_Inner  = 0x10;
static constexpr uint64_t kT_Matrix = 0x38;
static constexpr uint64_t kT_PosOff = 0x90;

// ─── Настройки магнита ──────────────────────────────────────────────
static constexpr float kMagnetStrength   = 0.08f;  // 8% за кадр — плавно
static constexpr float kMagnetMaxDist    = 50.0f;
static constexpr int   kMagnetTickMs     = 16;     // 60 Hz — как кадр игры

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_target   = 0;
static Vector3  mag_camPos   = {};
static Vector3  mag_camFwd   = {};

// Оригинал головы — читаем ОДИН раз при взятии цели, от него считаем всегда
static uint64_t mag_lastTarget  = 0;
static Vector3  mag_origHead    = {};
static bool     mag_origValid   = false;

// ─── Helpers ────────────────────────────────────────────────────────
static inline float dot3(Vector3 a, Vector3 b) {
    return a.x*b.x + a.y*b.y + a.z*b.z;
}
static inline float vlen3(Vector3 v) {
    return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
}
static inline bool isZeroVec(Vector3 v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// headTransNode → +0x10 → p3 → +0x38 → matPtr → write at +0x90
static bool WriteHeadPos(uint64_t pawn, Vector3 pos) {
    if (!isVaildPtr(pawn)) return false;
    uint64_t headNode = ReadAddr<uint64_t>(pawn + kHeadNode);
    if (!isVaildPtr(headNode)) return false;
    uint64_t transNode = ReadAddr<uint64_t>(headNode + kBodyPartTransNode);
    if (!isVaildPtr(transNode)) return false;
    uint64_t p3 = ReadAddr<uint64_t>(transNode + kT_Inner);
    if (!isVaildPtr(p3)) return false;
    uint64_t matPtr = ReadAddr<uint64_t>(p3 + kT_Matrix);
    if (!isVaildPtr(matPtr)) return false;

    WriteAddr<Vector3>(matPtr + kT_PosOff, pos);
    return true;
}

// ─── Worker ─────────────────────────────────────────────────────────
static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagnetTickMs));

        if (!mag_hasData.load(std::memory_order_acquire)) {
            // сброс при выключении
            mag_origValid  = false;
            mag_lastTarget = 0;
            continue;
        }

        uint64_t target;
        Vector3  camPos, camFwd;
        {
            std::lock_guard<std::mutex> lk(mag_lock);
            target = mag_target;
            camPos = mag_camPos;
            camFwd = mag_camFwd;
        }
        if (!isVaildPtr(target)) continue;

        // ─── Смена цели → сброс оригинала ──────────────────────────
        if (target != mag_lastTarget) {
            mag_lastTarget = target;
            mag_origValid  = false;
        }

        // ─── Один раз читаем оригинал головы ───────────────────────
        if (!mag_origValid) {
            Vector3 h = HeadPos(target);
            if (isZeroVec(h)) continue;
            mag_origHead  = h;
            mag_origValid = true;
            // Первый тик — просто запоминаем, не двигаем
            continue;
        }

        // ─── Считаем от ОРИГИНАЛА, не от свежей позиции ────────────
        Vector3 headPos = mag_origHead;

        Vector3 toEnemy = { headPos.x - camPos.x,
                            headPos.y - camPos.y,
                            headPos.z - camPos.z };
        float dist = vlen3(toEnemy);
        if (dist > kMagnetMaxDist || dist < 0.5f) continue;

        float projDist = dot3(toEnemy, camFwd);
        if (projDist < 0.5f) continue;

        // Точка на луче камеры на той же глубине
        Vector3 onRay = {
            camPos.x + camFwd.x * projDist,
            camPos.y + camFwd.y * projDist,
            camPos.z + camFwd.z * projDist
        };

        // Мягкий lerp от оригинала к точке на луче
        Vector3 newPos = {
            headPos.x + (onRay.x - headPos.x) * kMagnetStrength,
            headPos.y + (onRay.y - headPos.y) * kMagnetStrength,
            headPos.z + (onRay.z - headPos.z) * kMagnetStrength
        };

        WriteHeadPos(target, newPos);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward) {
    InitMagnetThread();

    if (!aimMagnet || !isVaildPtr(target)) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_target = target;
        mag_camPos = camPos;
        mag_camFwd = camForward;
    }
    mag_hasData.store(true, std::memory_order_release);
}

void ResetAimMagnet() {
    mag_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(mag_lock);
    mag_target = 0;

    mag_lastTarget = 0;
    mag_origValid  = false;
}
