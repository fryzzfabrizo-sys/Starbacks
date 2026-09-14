// magnet.mm
// Aim Magnet — displacement = radius − 1м запас.

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

// ─── root transform offset ──────────────────────────────
static constexpr uint64_t kMag_RootNode = 0x660;
static constexpr uint64_t kMag_BodyPart = 0x10;
static constexpr uint64_t kMag_Inner    = 0x10;
static constexpr uint64_t kMag_Matrix   = 0x38;
static constexpr uint64_t kMag_PosOff   = 0x90;

// ─── Параметры ──────────────────────────────────────────
// radius буста = 18.00 → displacement = 18 - 1 = 17.00 (запас 1м)
static constexpr float kMagStrength        = 1.00f;
static constexpr float kMagMaxDist         = 300.0f;
static constexpr float kMagMinDist         = 1.0f;
static constexpr float kMagMaxDisplacement = 20.00f;

static constexpr int   kMagTickMs     = 4;
static constexpr int   kMagReleaseMs  = 200;

static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_candidate = 0;
static Vector3  mag_camPos    = {};
static Vector3  mag_camFwd    = {};
static uint64_t mag_locked    = 0;

static Vector3  mag_originalRoot = {};
static bool     mag_originalRootValid = false;

static std::chrono::steady_clock::time_point mag_lastUpdate =
    std::chrono::steady_clock::now();

static inline float vlen3(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static inline float vlen2xz(Vector3 v) { return sqrtf(v.x*v.x + v.z*v.z); }
static inline bool  isZero3(Vector3 v) { return v.x==0.f && v.y==0.f && v.z==0.f; }
static inline bool  isSane3(Vector3 v) {
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return false;
    if (fabsf(v.x) > 20000.f || fabsf(v.y) > 20000.f || fabsf(v.z) > 20000.f) return false;
    return true;
}

static Vector3 HeadWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static Vector3 RootWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t node = ReadAddr<uint64_t>(pawn + kMag_RootNode);
    if (!isVaildPtr(node)) return {};
    uint64_t tf = ReadAddr<uint64_t>(node + kMag_BodyPart);
    if (!isVaildPtr(tf)) return {};
    return getPositionExt(tf);
}

static uint64_t MatPtr(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t node = ReadAddr<uint64_t>(pawn + kMag_RootNode);
    if (!isVaildPtr(node)) return 0;
    uint64_t tf = ReadAddr<uint64_t>(node + kMag_BodyPart);
    if (!isVaildPtr(tf)) return 0;
    uint64_t p3 = ReadAddr<uint64_t>(tf + kMag_Inner);
    if (!isVaildPtr(p3)) return 0;
    uint64_t mat = ReadAddr<uint64_t>(p3 + kMag_Matrix);
    return isVaildPtr(mat) ? mat : 0;
}

static bool WriteLocalRoot(uint64_t pawn, Vector3 pos) {
    if (!isSane3(pos)) return false;
    uint64_t mat = MatPtr(pawn);
    if (!isVaildPtr(mat)) return false;
    WriteAddr<Vector3>(mat + kMag_PosOff, pos);
    return true;
}

static bool ApplyMagnet(uint64_t pawn, const Vector3& camPos, const Vector3& camFwd) {
    Vector3 headW = HeadWorld(pawn);
    if (!isSane3(headW) || isZero3(headW)) return false;

    float dist = vlen3({headW.x - camPos.x, headW.y - camPos.y, headW.z - camPos.z});
    if (dist < kMagMinDist || dist > kMagMaxDist) return false;

    Vector3 curRootW = RootWorld(pawn);
    if (!isSane3(curRootW) || isZero3(curRootW)) return false;

    if (!mag_originalRootValid) return false;

    Vector3 targetPt = {
        camPos.x + camFwd.x * dist,
        camPos.y + camFwd.y * dist,
        camPos.z + camFwd.z * dist
    };

    Vector3 rootTgtWorld = {
        targetPt.x,
        mag_originalRoot.y,
        targetPt.z
    };

    Vector3 lerped = {
        curRootW.x + (rootTgtWorld.x - curRootW.x) * kMagStrength,
        mag_originalRoot.y,
        curRootW.z + (rootTgtWorld.z - curRootW.z) * kMagStrength
    };

    // Clamp: не дальше 17м от исходной позиции (radius 18 − 1м запас)
    Vector3 deltaOrig = { lerped.x - mag_originalRoot.x, 0.0f, lerped.z - mag_originalRoot.z };
    float dOrig = vlen2xz(deltaOrig);
    if (dOrig > kMagMaxDisplacement && dOrig > 0.0001f) {
        float s = kMagMaxDisplacement / dOrig;
        lerped.x = mag_originalRoot.x + deltaOrig.x * s;
        lerped.z = mag_originalRoot.z + deltaOrig.z * s;
    }

    return WriteLocalRoot(pawn, lerped);
}

static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagTickMs));

        auto now = std::chrono::steady_clock::now();
        auto since = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now - mag_lastUpdate).count();
        if (since > kMagReleaseMs) {
            mag_locked = 0;
            mag_originalRootValid = false;
            continue;
        }

        if (!mag_hasData.load(std::memory_order_acquire)) {
            mag_locked = 0;
            mag_originalRootValid = false;
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

        if (!isVaildPtr(mag_locked)) {
            if (isVaildPtr(candidate) && get_CurHP(candidate) > 0) {
                mag_locked = candidate;
                mag_originalRoot = RootWorld(candidate);
                mag_originalRootValid = isSane3(mag_originalRoot) && !isZero3(mag_originalRoot);
            }
            if (!isVaildPtr(mag_locked)) continue;
        }

        if (candidate != mag_locked || get_CurHP(mag_locked) <= 0) {
            mag_locked = 0;
            mag_originalRootValid = false;
            continue;
        }

        ApplyMagnet(mag_locked, camPos, camFwd);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward, bool enabled) {
    InitMagnetThread();

    if (!aimMagnet || !enabled || !isVaildPtr(target)) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_candidate = target;
        mag_camPos    = camPos;
        mag_camFwd    = camForward;
    }
    mag_lastUpdate = std::chrono::steady_clock::now();
    mag_hasData.store(true, std::memory_order_release);
}

void ResetAimMagnet() {
    mag_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(mag_lock);
    mag_candidate = 0;
    mag_camPos    = {};
    mag_camFwd    = {};
    mag_locked    = 0;
    mag_originalRoot = {};
    mag_originalRootValid = false;
}
