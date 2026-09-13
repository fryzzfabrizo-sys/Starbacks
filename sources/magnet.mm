// magnet.mm
// Aim magnet через root transform (safe world→local: root в world-фрейме)

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

// ─── Player field offsets ──────────────────────────────────────────
static constexpr uint64_t kMag_HeadNode = 0x638;   // Player_HeadTF (только чтение)
static constexpr uint64_t kMag_RootNode = 0x660;   // Player_RootTF (сюда пишем)
static constexpr uint64_t kMag_BodyPart = 0x10;    // ITransformNode -> Transform
static constexpr uint64_t kT_Inner      = 0x10;
static constexpr uint64_t kT_Matrix     = 0x38;
static constexpr uint64_t kT_PosOff     = 0x90;

// ─── Tuning ─────────────────────────────────────────────────────────
static constexpr float kMagStrength = 0.10f;
static constexpr float kMagMaxDist  = 60.0f;
static constexpr float kMagMinDist  = 0.5f;
static constexpr int   kMagTickMs   = 16;

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_candidate  = 0;
static Vector3  mag_camPos     = {};
static Vector3  mag_camFwd     = {};

static uint64_t mag_locked     = 0;
static Vector3  mag_savedLocal = {};
static bool     mag_saved      = false;

// ─── Utils ──────────────────────────────────────────────────────────
static inline float vlen3(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static inline float dot3(Vector3 a, Vector3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static inline bool isZero3(Vector3 v) { return v.x==0.f && v.y==0.f && v.z==0.f; }
static inline bool isSane3(Vector3 v) {
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return false;
    if (fabsf(v.x) > 10000.f || fabsf(v.y) > 10000.f || fabsf(v.z) > 10000.f) return false;
    return true;
}

// world head pos — только чтение
static Vector3 HeadWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Достаём указатель на matrix у root-ноды
static uint64_t RootMatrixPtr(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t node = ReadAddr<uint64_t>(pawn + kMag_RootNode);
    if (!isVaildPtr(node)) return 0;
    uint64_t tf = ReadAddr<uint64_t>(node + kMag_BodyPart);
    if (!isVaildPtr(tf)) return 0;
    uint64_t p3 = ReadAddr<uint64_t>(tf + kT_Inner);
    if (!isVaildPtr(p3)) return 0;
    uint64_t mat = ReadAddr<uint64_t>(p3 + kT_Matrix);
    return isVaildPtr(mat) ? mat : 0;
}

static bool RootReadLocal(uint64_t pawn, Vector3& out) {
    uint64_t mat = RootMatrixPtr(pawn);
    if (!isVaildPtr(mat)) return false;
    out = ReadAddr<Vector3>(mat + kT_PosOff);
    return isSane3(out);
}

static bool RootWriteLocal(uint64_t pawn, Vector3 pos) {
    if (!isSane3(pos)) return false;
    uint64_t mat = RootMatrixPtr(pawn);
    if (!isVaildPtr(mat)) return false;
    WriteAddr<Vector3>(mat + kT_PosOff, pos);
    return true;
}

static void ReleaseLock() {
    if (mag_saved && isVaildPtr(mag_locked)) {
        RootWriteLocal(mag_locked, mag_savedLocal);
    }
    mag_locked = 0;
    mag_saved  = false;
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

        // Захват
        if (!isVaildPtr(mag_locked)) {
            mag_locked = 0;
            mag_saved  = false;

            if (isVaildPtr(candidate) && get_CurHP(candidate) > 0) {
                Vector3 lp;
                if (RootReadLocal(candidate, lp)) {
                    mag_locked     = candidate;
                    mag_savedLocal = lp;
                    mag_saved      = true;
                }
            }
            if (!isVaildPtr(mag_locked)) continue;
        }

        // Цель умерла / освобождена
        if (get_CurHP(mag_locked) <= 0) {
            ReleaseLock();
            continue;
        }

        // Проверка pointer-цепочки (иначе GC крашится)
        Vector3 headW = HeadWorld(mag_locked);
        if (!isSane3(headW) || isZero3(headW)) { ReleaseLock(); continue; }

        Vector3 toHead = { headW.x - camPos.x,
                           headW.y - camPos.y,
                           headW.z - camPos.z };
        float dist = vlen3(toHead);
        if (dist < kMagMinDist || dist > kMagMaxDist) continue;

        float proj = dot3(toHead, camFwd);
        if (proj < 0.5f) continue;

        Vector3 onRay = {
            camPos.x + camFwd.x * proj,
            camPos.y + camFwd.y * proj,
            camPos.z + camFwd.z * proj
        };

        // Delta от оригинала в world-фрейме → root local (у него world == local)
        Vector3 savedWorld = mag_savedLocal;   // для root это уже world
        Vector3 targetWorld = {
            savedWorld.x + (onRay.x - headW.x),
            savedWorld.y + (onRay.y - headW.y),
            savedWorld.z + (onRay.z - headW.z)
        };

        Vector3 newLocal = {
            savedWorld.x + (targetWorld.x - savedWorld.x) * kMagStrength,
            savedWorld.y + (targetWorld.y - savedWorld.y) * kMagStrength,
            savedWorld.z + (targetWorld.z - savedWorld.z) * kMagStrength
        };

        RootWriteLocal(mag_locked, newLocal);
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
