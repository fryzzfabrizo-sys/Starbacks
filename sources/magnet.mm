// magnet.mm
// Aim Magnet — быстрый тик, жёсткая привязка, авто-релиз по таймауту

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

// ═══════════════════════════════════════════════════════════════════
//  РЕЖИМ
//  0 = root (0x660)   1 = head (0x638)
// ═══════════════════════════════════════════════════════════════════
static constexpr int kMagMode = 0;

// ─── Offsets ────────────────────────────────────────────────────────
static constexpr uint64_t kMag_HeadNode = 0x638;
static constexpr uint64_t kMag_RootNode = 0x660;
static constexpr uint64_t kMag_BodyPart = 0x10;
static constexpr uint64_t kMag_Inner    = 0x10;
static constexpr uint64_t kMag_Matrix   = 0x38;
static constexpr uint64_t kMag_PosOff   = 0x90;

// ─── Tuning ─────────────────────────────────────────────────────────
static constexpr float kMagStrength    = 0.55f;    // ↑↑ против анимации
static constexpr float kMagHeadOffset  = 1.5f;
static constexpr float kMagMaxDist     = 80.0f;
static constexpr float kMagMinDist     = 0.6f;
static constexpr int   kMagTickMs      = 8;        // 120 Hz — быстрее кадра
static constexpr float kMagMaxDelta    = 1.50f;    // ↑↑ больше шаг
static constexpr int   kMagReleaseMs   = 200;      // если нет данных — релиз

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_candidate = 0;
static Vector3  mag_camPos    = {};
static Vector3  mag_camFwd    = {};
static uint64_t mag_locked    = 0;

static std::chrono::steady_clock::time_point mag_lastUpdate =
    std::chrono::steady_clock::now();

// ─── Utils ──────────────────────────────────────────────────────────
static inline float vlen3(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
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

static uint64_t MatPtr(uint64_t pawn, uint64_t nodeOff) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t node = ReadAddr<uint64_t>(pawn + nodeOff);
    if (!isVaildPtr(node)) return 0;
    uint64_t tf = ReadAddr<uint64_t>(node + kMag_BodyPart);
    if (!isVaildPtr(tf)) return 0;
    uint64_t p3 = ReadAddr<uint64_t>(tf + kMag_Inner);
    if (!isVaildPtr(p3)) return 0;
    uint64_t mat = ReadAddr<uint64_t>(p3 + kMag_Matrix);
    return isVaildPtr(mat) ? mat : 0;
}

static bool ReadLocalAt(uint64_t pawn, uint64_t nodeOff, Vector3& out) {
    uint64_t mat = MatPtr(pawn, nodeOff);
    if (!isVaildPtr(mat)) return false;
    out = ReadAddr<Vector3>(mat + kMag_PosOff);
    return isSane3(out);
}

static bool WriteLocalAt(uint64_t pawn, uint64_t nodeOff, Vector3 pos) {
    if (!isSane3(pos)) return false;
    uint64_t mat = MatPtr(pawn, nodeOff);
    if (!isVaildPtr(mat)) return false;
    WriteAddr<Vector3>(mat + kMag_PosOff, pos);
    return true;
}

// ─── Core step ──────────────────────────────────────────────────────
static bool ComputeMagnetStep(uint64_t pawn,
                              const Vector3& camPos,
                              const Vector3& camFwd,
                              Vector3& outTargetLocal)
{
    Vector3 headW = HeadWorld(pawn);
    if (!isSane3(headW) || isZero3(headW)) return false;

    float dist = vlen3({headW.x - camPos.x, headW.y - camPos.y, headW.z - camPos.z});
    if (dist < kMagMinDist || dist > kMagMaxDist) return false;

    Vector3 targetPt = {
        camPos.x + camFwd.x * dist,
        camPos.y + camFwd.y * dist,
        camPos.z + camFwd.z * dist
    };
    Vector3 rootTgtWorld = {
        targetPt.x,
        targetPt.y - kMagHeadOffset,
        targetPt.z
    };

    Vector3 curRootWorld = RootWorld(pawn);
    if (!isSane3(curRootWorld) || isZero3(curRootWorld)) return false;

    Vector3 deltaWorld = {
        rootTgtWorld.x - curRootWorld.x,
        rootTgtWorld.y - curRootWorld.y,
        rootTgtWorld.z - curRootWorld.z
    };

    Vector3 curLocal;
    if (!ReadLocalAt(pawn, kMag_RootNode, curLocal)) return false;

    Vector3 step = {
        deltaWorld.x * kMagStrength,
        deltaWorld.y * kMagStrength,
        deltaWorld.z * kMagStrength
    };

    float slen = vlen3(step);
    if (slen > kMagMaxDelta) {
        float s = kMagMaxDelta / slen;
        step.x *= s; step.y *= s; step.z *= s;
    }

    outTargetLocal = {
        curLocal.x + step.x,
        curLocal.y + step.y,
        curLocal.z + step.z
    };
    return true;
}

// ─── Worker ─────────────────────────────────────────────────────────
static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagTickMs));

        // Авто-релиз: если давно не было данных — отпускаем цель
        auto now = std::chrono::steady_clock::now();
        auto since = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now - mag_lastUpdate).count();
        if (since > kMagReleaseMs) {
            mag_locked = 0;
            continue;
        }

        if (!mag_hasData.load(std::memory_order_acquire)) {
            mag_locked = 0;
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
            }
            if (!isVaildPtr(mag_locked)) continue;
        }

        if (get_CurHP(mag_locked) <= 0) {
            mag_locked = 0;
            continue;
        }

        Vector3 newLocal;
        if (!ComputeMagnetStep(mag_locked, camPos, camFwd, newLocal)) continue;

        if (kMagMode == 1) {
            WriteLocalAt(mag_locked, kMag_HeadNode, newLocal);
        } else {
            WriteLocalAt(mag_locked, kMag_RootNode, newLocal);
        }
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward, bool isFiring) {
    InitMagnetThread();

    // Если не стреляем или нет цели — сразу стоп
    if (!aimMagnet || !isFiring || !isVaildPtr(target)) {
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
}
