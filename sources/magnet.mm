// magnet.mm
// Lock-based aim magnet. Один лок на цель. Delta-запись, без world-in-local.

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

// ─── Transform chain ────────────────────────────────────────────────
static constexpr uint64_t kMag_HeadNode     = 0x638;
static constexpr uint64_t kMag_BodyPartNode = 0x10;
static constexpr uint64_t kMag_Inner        = 0x10;
static constexpr uint64_t kMag_Matrix       = 0x38;
static constexpr uint64_t kMag_PosOff       = 0x90;

// ─── Tuning ─────────────────────────────────────────────────────────
static constexpr float kMagStrength   = 0.20f;
static constexpr float kMagMaxDist    = 60.0f;
static constexpr float kMagMinDist    = 0.5f;
static constexpr int   kMagTickMs     = 15;

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

// ─── Bone local position access ─────────────────────────────────────
static bool BoneReadLocal(uint64_t pawn, Vector3& outPos) {
    if (!isVaildPtr(pawn)) return false;
    uint64_t bone = ReadAddr<uint64_t>(pawn + kMag_HeadNode);
    if (!isVaildPtr(bone)) return false;
    uint64_t trans = ReadAddr<uint64_t>(bone + kMag_BodyPartNode);
    if (!isVaildPtr(trans)) return false;
    uint64_t p3 = ReadAddr<uint64_t>(trans + kMag_Inner);
    if (!isVaildPtr(p3)) return false;
    uint64_t mat = ReadAddr<uint64_t>(p3 + kMag_Matrix);
    if (!isVaildPtr(mat)) return false;
    outPos = ReadAddr<Vector3>(mat + kMag_PosOff);
    return true;
}

static bool BoneWriteLocal(uint64_t pawn, Vector3 pos) {
    if (!isVaildPtr(pawn)) return false;
    uint64_t bone = ReadAddr<uint64_t>(pawn + kMag_HeadNode);
    if (!isVaildPtr(bone)) return false;
    uint64_t trans = ReadAddr<uint64_t>(bone + kMag_BodyPartNode);
    if (!isVaildPtr(trans)) return false;
    uint64_t p3 = ReadAddr<uint64_t>(trans + kMag_Inner);
    if (!isVaildPtr(p3)) return false;
    uint64_t mat = ReadAddr<uint64_t>(p3 + kMag_Matrix);
    if (!isVaildPtr(mat)) return false;
    WriteAddr<Vector3>(mat + kMag_PosOff, pos);
    return true;
}

static Vector3 HeadWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ─── Release lock с восстановлением оригинала ──────────────────────
static void ReleaseLock() {
    if (mag_saved && isVaildPtr(mag_locked)) {
        BoneWriteLocal(mag_locked, mag_savedLocal);
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

        if (!isVaildPtr(mag_locked)) {
            mag_locked = 0;
            mag_saved  = false;

            if (isVaildPtr(candidate) && get_CurHP(candidate) > 0) {
                Vector3 lp;
                if (BoneReadLocal(candidate, lp)) {
                    mag_locked     = candidate;
                    mag_savedLocal = lp;
                    mag_saved      = true;
                }
            }
            if (!isVaildPtr(mag_locked)) continue;
        }

        if (get_CurHP(mag_locked) <= 0) {
            ReleaseLock();
            continue;
        }

        Vector3 headW = HeadWorld(mag_locked);
        if (isZero3(headW)) { ReleaseLock(); continue; }

        Vector3 toHead = { headW.x - camPos.x,
                           headW.y - camPos.y,
                           headW.z - camPos.z };
        float dist = vlen3(toHead);
        if (dist < kMagMinDist || dist > kMagMaxDist) continue;

        float proj = dot3(toHead, camFwd);
        if (proj < 0.5f) continue;

        Vector3 desired = {
            camPos.x + camFwd.x * proj,
            camPos.y + camFwd.y * proj,
            camPos.z + camFwd.z * proj
        };

        Vector3 delta = { (desired.x - headW.x) * kMagStrength,
                          (desired.y - headW.y) * kMagStrength,
                          (desired.z - headW.z) * kMagStrength };

        Vector3 curLocal;
        if (!BoneReadLocal(mag_locked, curLocal)) { ReleaseLock(); continue; }

        Vector3 newLocal = { curLocal.x + delta.x,
                             curLocal.y + delta.y,
                             curLocal.z + delta.z };

        BoneWriteLocal(mag_locked, newLocal);
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
