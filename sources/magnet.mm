// magnet.mm
// Aim magnet через PhysCCT.Velocity (безопасно, не трогаем Unity transforms)

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimMagnet;

// ─── Player -> PhysicalCCT -> Velocity ──────────────────────────────
static constexpr uint64_t kMag_PhysCCT     = 0x200;   // kPhysCCT
static constexpr uint64_t kMag_Velocity    = 0x17C;   // kPhysCCT_Velocity
static constexpr uint64_t kMag_HeadNode    = 0x638;   // Player_HeadTF (только чтение)

// ─── Tuning ─────────────────────────────────────────────────────────
static constexpr float kMagStrength = 0.50f;    // 50% от delta за тик
static constexpr float kMagMaxDist  = 60.0f;
static constexpr float kMagMinDist  = 0.8f;
static constexpr int   kMagTickMs   = 16;       // 60 Hz — синхронно с физикой
static constexpr float kMagMaxVel   = 1500.0f;  // чтобы не улетел в небо

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_candidate = 0;
static Vector3  mag_camPos    = {};
static Vector3  mag_camFwd    = {};

static uint64_t mag_locked    = 0;

// ─── Utils ──────────────────────────────────────────────────────────
static inline float vlen3(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static inline float dot3(Vector3 a, Vector3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static inline bool isZero3(Vector3 v) { return v.x==0.f && v.y==0.f && v.z==0.f; }
static inline bool isSane3(Vector3 v) {
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return false;
    if (fabsf(v.x) > 10000.f || fabsf(v.y) > 10000.f || fabsf(v.z) > 10000.f) return false;
    return true;
}

// World head pos — только чтение
static Vector3 HeadWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Получить указатель на PhysicalCCT игрока
static uint64_t GetCCT(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t cct = ReadAddr<uint64_t>(pawn + kMag_PhysCCT);
    return isVaildPtr(cct) ? cct : 0;
}

// Записать velocity
static bool WriteVelocity(uint64_t pawn, Vector3 vel) {
    if (!isSane3(vel)) return false;
    uint64_t cct = GetCCT(pawn);
    if (!isVaildPtr(cct)) return false;
    WriteAddr<Vector3>(cct + kMag_Velocity, vel);
    return true;
}

// Обнулить velocity при отпускании
static void ReleaseLock() {
    if (isVaildPtr(mag_locked)) {
        uint64_t cct = GetCCT(mag_locked);
        if (isVaildPtr(cct)) {
            WriteAddr<Vector3>(cct + kMag_Velocity, Vector3{0.f, 0.f, 0.f});
        }
    }
    mag_locked = 0;
}

// ─── Worker ─────────────────────────────────────────────────────────
static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagTickMs));

        if (!mag_hasData.load(std::memory_order_acquire)) {
            ReleaseLock();
            continue;
        }

        uint64_t candidate;
        Vector3  camPos, camFwd;
        {
            std::lock_guard<std::mutex> lk(mag_lock);
            candidate = mag_candidate;
            camPos    = mag_camPos;
            camFwd    = mag_camFwd;
        }

        // Захват цели
        if (!isVaildPtr(mag_locked)) {
            mag_locked = 0;

            if (isVaildPtr(candidate) && get_CurHP(candidate) > 0) {
                // Проверяем что CCT есть
                if (isVaildPtr(GetCCT(candidate))) {
                    mag_locked = candidate;
                }
            }
            if (!isVaildPtr(mag_locked)) continue;
        }

        // Проверка цели
        if (get_CurHP(mag_locked) <= 0 || !isVaildPtr(GetCCT(mag_locked))) {
            ReleaseLock();
            continue;
        }

        Vector3 headW = HeadWorld(mag_locked);
        if (!isSane3(headW) || isZero3(headW)) { ReleaseLock(); continue; }

        // Проекция на луч камеры
        Vector3 toHead = { headW.x - camPos.x,
                           headW.y - camPos.y,
                           headW.z - camPos.z };
        float dist = vlen3(toHead);
        if (dist < kMagMinDist || dist > kMagMaxDist) continue;

        float proj = dot3(toHead, camFwd);
        if (proj < 0.5f) continue;

        // Точка на луче камеры на той же глубине
        Vector3 onRay = {
            camPos.x + camFwd.x * proj,
            camPos.y + camFwd.y * proj,
            camPos.z + camFwd.z * proj
        };

        // delta = куда нужно сдвинуть
        Vector3 delta = { onRay.x - headW.x,
                          onRay.y - headW.y,
                          onRay.z - headW.z };
        float dlen = vlen3(delta);
        if (dlen < 0.05f) continue;   // цель уже на кроссхаире

        // velocity = delta / dt * strength
        // dt = kMagTickMs / 1000
        float dt = kMagTickMs / 1000.0f;
        float k = kMagStrength / dt;   // например 0.5 / 0.016 = 31.25

        Vector3 vel = { delta.x * k, delta.y * k, delta.z * k };

        // Ограничиваем скорость
        float vlen = vlen3(vel);
        if (vlen > kMagMaxVel) {
            float s = kMagMaxVel / vlen;
            vel.x *= s;
            vel.y *= s;
            vel.z *= s;
        }

        WriteVelocity(mag_locked, vel);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward, bool isFiring) {
    InitMagnetThread();

    if (!aimMagnet || !isFiring) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_candidate = target;
        mag_camPos    = camPos;
        mag_camFwd    = camForward;
    }
    mag_hasData.store(true, std::memory_order_release);
}

void ResetAimMagnet() {
    mag_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(mag_lock);
    mag_candidate = 0;
    mag_camPos    = {};
    mag_camFwd    = {};
}
