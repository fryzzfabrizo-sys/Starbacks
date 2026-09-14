// magnet.mm
// Aim Magnet с удержанием цели.
//   • не переключает цель пока она жива (и не нокнута/не бот при включённых флагах)
//   • переприцеливание (выход из ADS → новый захват) сбрасывает цель
//   • соблюдает isAimIgnoreBot / isAimIgnoreKnock

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

// Флаги фильтров из esp.mm
extern bool isAimIgnoreBot;
extern bool isAimIgnoreKnock;

// Хелперы проверки состояния из esp.mm
extern bool get_IsBot(uint64_t player);
extern bool get_IsKnockedDown(uint64_t player);

// ─── root transform offset ──────────────────────────────
static constexpr uint64_t kMag_RootNode = 0x660;
static constexpr uint64_t kMag_BodyPart = 0x10;
static constexpr uint64_t kMag_Inner    = 0x10;
static constexpr uint64_t kMag_Matrix   = 0x38;
static constexpr uint64_t kMag_PosOff   = 0x90;

// ─── Параметры ──────────────────────────────────────────
static constexpr float kMagStrength        = 1.00f;
static constexpr float kMagMaxDist         = 500.0f;
static constexpr float kMagMinDist         = 1.0f;
static constexpr float kMagMaxDisplacement = 8.00f;

static constexpr int   kMagTickMs     = 4;
static constexpr int   kMagReleaseMs  = 200;

static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

// Управляется из main thread
static uint64_t mag_locked    = 0;
static Vector3  mag_originalRoot = {};
static bool     mag_originalRootValid = false;

// Обновляется из main thread, читается воркером
static Vector3  mag_camPos    = {};
static Vector3  mag_camFwd    = {};

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

// Цель всё ещё подходит для удержания?
static bool TargetStillValid(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return false;
    if (get_CurHP(pawn) <= 0) return false;
    if (isAimIgnoreBot   && get_IsBot(pawn))         return false;
    if (isAimIgnoreKnock && get_IsKnockedDown(pawn)) return false;
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

    Vector3 deltaOrig = { lerped.x - mag_originalRoot.x, 0.0f, lerped.z - mag_originalRoot.z };
    float dOrig = vlen2xz(deltaOrig);
    if (dOrig > kMagMaxDisplacement && dOrig > 0.0001f) {
        float s = kMagMaxDisplacement / dOrig;
        lerped.x = mag_originalRoot.x + deltaOrig.x * s;
        lerped.z = mag_originalRoot.z + deltaOrig.z * s;
    }

    return WriteLocalRoot(pawn, lerped);
}

// ─── Воркер ─────────────────────────────────────────────
static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagTickMs));

        auto now = std::chrono::steady_clock::now();
        auto since = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now - mag_lastUpdate).count();
        if (since > kMagReleaseMs) {
            mag_hasData.store(false, std::memory_order_release);
            continue;
        }

        if (!mag_hasData.load(std::memory_order_acquire)) continue;

        uint64_t target;
        Vector3 camPos, camFwd;
        {
            std::lock_guard<std::mutex> lk(mag_lock);
            target = mag_locked;
            camPos = mag_camPos;
            camFwd = mag_camFwd;
        }

        if (!isVaildPtr(target)) continue;
        if (!TargetStillValid(target)) continue;

        ApplyMagnet(target, camPos, camFwd);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

// ─── Called each frame из esp.mm (main thread) ───────────
void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward, bool enabled) {
    InitMagnetThread();

    if (!aimMagnet || !enabled) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    // ── Логика удержания цели ────────────────────────────
    if (isVaildPtr(mag_locked)) {
        if (!TargetStillValid(mag_locked)) {
            mag_locked = 0;
            mag_originalRootValid = false;
        }
    }

    if (!isVaildPtr(mag_locked)) {
        if (isVaildPtr(target) && TargetStillValid(target)) {
            mag_locked = target;
            mag_originalRoot = RootWorld(target);
            mag_originalRootValid = isSane3(mag_originalRoot) && !isZero3(mag_originalRoot);
        }
    }

    if (!isVaildPtr(mag_locked)) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_camPos = camPos;
        mag_camFwd = camForward;
    }
    mag_lastUpdate = std::chrono::steady_clock::now();
    mag_hasData.store(true, std::memory_order_release);

    ApplyMagnet(mag_locked, camPos, camForward);
}

void ResetAimMagnet() {
    mag_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(mag_lock);
    mag_locked = 0;
    mag_camPos = {};
    mag_camFwd = {};
    mag_originalRoot = {};
    mag_originalRootValid = false;
}
