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

// ═══ Silent Aim offsets ═══
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_Scatter        = 0x5C;

// ═══ Magnet offsets ═══
static constexpr uint64_t kMainCameraTransform = 0x380;
static constexpr uint64_t kHeadNode            = 0x638;
static constexpr uint64_t kBodyPartTransNode   = 0x10;
static constexpr uint64_t kT_Inner             = 0x10;
static constexpr uint64_t kT_Matrix            = 0x38;
static constexpr uint64_t kT_PosOff            = 0x90;

static constexpr float kMagnetStrength = 0.4f;
static constexpr float kMagnetMaxDist  = 50.0f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr         = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_lastLocal  = 0;
static uint64_t          g_lastTarget = 0;
static uint64_t          g_lastMatch  = 0;

static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};
static uint64_t          mag_target = 0;
static Vector3           mag_camPos = {};
static Vector3           mag_camFwd = {};

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline float dot3(Vector3 a, Vector3 b) {
    return a.x*b.x + a.y*b.y + a.z*b.z;
}
static inline float vlen3(Vector3 v) {
    return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══ Запись позиции головы ═══
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
    WriteAddr<Vector3>(matPtr + kT_PosOff, pos);
    return true;
}

// ═══════════════════════════════════════════════════════════════
//  SILENT WORKER
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            lPos = g_lPos;
            vel  = g_targetVelocity;
        }
        if (!validPtr(h)) continue;

        Vector3 predPos = {
            tPos.x + vel.x * 0.06f,
            tPos.y + vel.y * 0.06f,
            tPos.z + vel.z * 0.06f
        };

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { predPos.x - origin.x, predPos.y - origin.y, predPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
        WriteAddr<float>(h + kHit_Scatter, 0.0f);
    }
}

// ═══════════════════════════════════════════════════════════════
//  MAGNET WORKER
// ═══════════════════════════════════════════════════════════════
static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(50));

        if (!mag_hasData.load(std::memory_order_acquire)) continue;

        uint64_t target;
        Vector3  camPos, camFwd;
        {
            std::lock_guard<std::mutex> lk(mag_lock);
            target = mag_target;
            camPos = mag_camPos;
            camFwd = mag_camFwd;
        }
        if (!isVaildPtr(target)) continue;

        Vector3 headPos = HeadPos(target);
        if (headPos.x == 0 && headPos.y == 0 && headPos.z == 0) continue;

        Vector3 toEnemy = { headPos.x-camPos.x, headPos.y-camPos.y, headPos.z-camPos.z };
        float dist = vlen3(toEnemy);
        if (dist > kMagnetMaxDist || dist < 0.5f) continue;

        float projDist = dot3(toEnemy, camFwd);
        if (projDist < 0.5f) continue;

        Vector3 onRay = {
            camPos.x + camFwd.x * projDist,
            camPos.y + camFwd.y * projDist,
            camPos.z + camFwd.z * projDist
        };

        Vector3 newPos = {
            headPos.x + (onRay.x - headPos.x) * kMagnetStrength,
            headPos.y + (onRay.y - headPos.y) * kMagnetStrength,
            headPos.z + (onRay.z - headPos.z) * kMagnetStrength
        };

        WriteHeadPos(target, newPos);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    mag_hasData.store(false, std::memory_order_release);
    g_lastLocal      = 0;
    g_lastTarget     = 0;
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
    }
    {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_target = 0;
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — одна функция, работает молча
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();
    InitMagnetThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        g_lastMatch = 0;
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

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        mag_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        mag_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        mag_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    // Скорость цели
    if (g_prevTargetPos.x != 0.0f || g_prevTargetPos.y != 0.0f || g_prevTargetPos.z != 0.0f) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float distSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        if (distSq < 25.0f) {
            g_targetVelocity = delta;
        } else {
            g_targetVelocity = {0.0f, 0.0f, 0.0f};
        }
    } else {
        g_targetVelocity = {0.0f, 0.0f, 0.0f};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_lPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенный пинг silent
    if (validPtr(aimPtr)) {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = g_lPos;
        Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq > 0.0001f) {
            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };
            WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
            WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);
        }
    }

    // ═══ AIM MAGNET — всегда с silent ═══
    uint64_t camTf = ReadAddr<uint64_t>(local + kMainCameraTransform);
    if (isVaildPtr(camTf)) {
        Vector3 camPos = getPositionExt(camTf);

        float *vm = GetViewMatrix(CameraMain(cachedMatch));
        Vector3 camFwd = {0, 0, 0};
        if (vm) {
            camFwd.x = -vm[2];
            camFwd.y = -vm[6];
            camFwd.z = -vm[10];
            float len = sqrtf(camFwd.x*camFwd.x + camFwd.y*camFwd.y + camFwd.z*camFwd.z);
            if (len > 0.001f) {
                camFwd.x /= len; camFwd.y /= len; camFwd.z /= len;
            }
        }

        if (camPos.x != 0.0f || camPos.y != 0.0f || camPos.z != 0.0f) {
            std::lock_guard<std::mutex> lk(mag_lock);
            mag_target = target;
            mag_camPos = camPos;
            mag_camFwd = camFwd;
            mag_hasData.store(true, std::memory_order_release);
        }
    }
}
