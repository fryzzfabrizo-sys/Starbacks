#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <map>
#include <mutex>
#include <thread>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ═══════════════════════════════════════════════════════════════
//  OFFSETS (OB54 / iOS 1.126.1)
// ═══════════════════════════════════════════════════════════════
static constexpr uint64_t kPlayer_LastAimInfo  = 0xDC8;
static constexpr uint64_t kHit_RayDir          = 0x40;
static constexpr uint64_t kHit_StartPos        = 0x4C;
static constexpr uint64_t kMainCameraTransform = 0x380;

// Transform internal (Unity)
static constexpr uint64_t kTransformHierarchy  = 0x10;
static constexpr uint64_t kTransformIndex      = 0x40;
// В hierarchy:
static constexpr uint64_t kHierarchyPositions  = 0x18;   // Vector3* localPositions
static constexpr uint64_t kHierarchyMatrices   = 0x38;   // Matrix4x4* worldTransforms
static constexpr uint64_t kMatrixStride        = 0x40;   // 64 байта на Matrix4x4
static constexpr uint64_t kMatrixPosOff        = 0x30;   // смещение позиции в матрице

static constexpr float kHeadCenterY = 0.055f;

// ═══════════════════════════════════════════════════════════════
//  AIM MAGNET STATE
// ═══════════════════════════════════════════════════════════════
static std::atomic<bool>  g_magnetEnabled{false};
static std::atomic<float> g_magnetStrength{0.35f};
static std::atomic<float> g_magnetMaxDist{22.0f};
static std::atomic<float> g_magnetCamDown{0.85f};

static std::mutex s_magnetLock;
static std::map<uint64_t, Vector3> s_basePos;

// ═══════════════════════════════════════════════════════════════
//  SILENT STATE
// ═══════════════════════════════════════════════════════════════
static constexpr uint64_t kTransitionCooldownMs = 500;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<uint64_t> g_transitionTick{0};

static uint64_t g_aimPtr   = 0;
static uint64_t g_local    = 0;
static uint64_t g_target   = 0;
static Vector3  g_headPos  = {};
static Vector3  g_localPos = {};

static uint64_t g_lastMatch  = 0;
static float   *g_viewMatrix = nullptr;

// ═══════════════════════════════════════════════════════════════
//  Хелперы
// ═══════════════════════════════════════════════════════════════
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
static inline float DotV3(const Vector3 &a, const Vector3 &b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

static Vector3 GetForwardFromMatrix(float *m) {
    if (!m) return {0, 0, 0};
    Vector3 f = { -m[2], -m[6], -m[10] };
    float len = std::sqrt(f.x*f.x + f.y*f.y + f.z*f.z);
    if (len < 0.001f) return {0, 0, 0};
    return { f.x/len, f.y/len, f.z/len };
}

// ═══════════════════════════════════════════════════════════════
//  SetTransformPosition — правильная Unity-цепочка
//  Transform +0x10 → hierarchy
//  hierarchy +0x38 → Matrix4x4*
//  matrix[index*0x40 + 0x30..0x38] = world position
//  Fallback через localPositions (hierarchy +0x18)
// ═══════════════════════════════════════════════════════════════
static bool SetTransformPosition(uint64_t transformPtr, const Vector3 &pos) {
    if (!validPtr(transformPtr)) return false;

    uint64_t hierarchy = ReadAddr<uint64_t>(transformPtr + kTransformHierarchy);
    if (!validPtr(hierarchy)) return false;

    int index = ReadAddr<int>(transformPtr + kTransformIndex);
    if (index < 0 || index > 100000) return false;

    // Вариант A: world matrices
    uint64_t matrices = ReadAddr<uint64_t>(hierarchy + kHierarchyMatrices);
    if (validPtr(matrices)) {
        uint64_t mat = matrices + (uint64_t)index * kMatrixStride;
        WriteAddr<float>(mat + kMatrixPosOff + 0, pos.x);
        WriteAddr<float>(mat + kMatrixPosOff + 4, pos.y);
        WriteAddr<float>(mat + kMatrixPosOff + 8, pos.z);
        return true;
    }

    // Вариант B: localPositions
    uint64_t positions = ReadAddr<uint64_t>(hierarchy + kHierarchyPositions);
    if (validPtr(positions)) {
        WriteAddr<Vector3>(positions + (uint64_t)index * 12, pos);
        return true;
    }

    return false;
}

// ═══════════════════════════════════════════════════════════════
//  AIM MAGNET update
// ═══════════════════════════════════════════════════════════════
static void UpdateMagnet(uint64_t local, uint64_t target, float *viewMatrix) {
    if (!g_magnetEnabled.load(std::memory_order_acquire)) {
        if (!s_basePos.empty()) {
            std::lock_guard<std::mutex> lk(s_magnetLock);
            s_basePos.clear();
        }
        return;
    }
    if (!isVaildPtr(local) || !isVaildPtr(target)) return;
    if (!viewMatrix) return;

    // Camera position
    uint64_t camTf = ReadAddr<uint64_t>(local + kMainCameraTransform);
    if (!isVaildPtr(camTf)) return;
    Vector3 camPos = getPositionExt(camTf);
    if (isZeroV3(camPos)) return;
    camPos.y -= g_magnetCamDown.load();

    // Forward
    Vector3 forward = GetForwardFromMatrix(viewMatrix);
    if (isZeroV3(forward)) return;

    // Target head
    uint64_t targetHead = getHead(target);
    if (!isVaildPtr(targetHead)) return;
    Vector3 headPos = getPositionExt(targetHead);

    // Distance check
    float dx = headPos.x - camPos.x;
    float dy = headPos.y - camPos.y;
    float dz = headPos.z - camPos.z;
    float dist = std::sqrt(dx*dx + dy*dy + dz*dz);
    if (dist > g_magnetMaxDist.load()) {
        std::lock_guard<std::mutex> lk(s_magnetLock);
        s_basePos.erase(target);
        return;
    }

    // Base position (сохраняем один раз при захвате)
    Vector3 basePos;
    {
        std::lock_guard<std::mutex> lk(s_magnetLock);
        auto it = s_basePos.find(target);
        if (it == s_basePos.end()) {
            s_basePos[target] = headPos;
            basePos = headPos;
        } else {
            basePos = it->second;
        }
    }

    // Проекция basePos на forward-луч
    Vector3 toEnemy = { basePos.x - camPos.x, basePos.y - camPos.y, basePos.z - camPos.z };
    float projectedDist = DotV3(toEnemy, forward);
    if (projectedDist < 0.0f) return;

    Vector3 targetOnRay = {
        camPos.x + forward.x * projectedDist,
        camPos.y + forward.y * projectedDist,
        camPos.z + forward.z * projectedDist
    };

    // Lerp между текущей позицией головы и точкой на луче
    float s = g_magnetStrength.load();
    Vector3 newPos = {
        headPos.x + (targetOnRay.x - headPos.x) * s,
        headPos.y + (targetOnRay.y - headPos.y) * s,
        headPos.z + (targetOnRay.z - headPos.z) * s
    };

    SetTransformPosition(targetHead, newPos);
}

// ═══════════════════════════════════════════════════════════════
//  SILENT WORKER — yield без sleep
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_acquire);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::yield();
            continue;
        }

        // AIM MAGNET
        if (g_magnetEnabled.load(std::memory_order_acquire)) {
            uint64_t local, target;
            {
                std::lock_guard<std::mutex> lk(g_lock);
                local  = g_local;
                target = g_target;
            }
            if (isVaildPtr(local) && isVaildPtr(target)) {
                UpdateMagnet(local, target, g_viewMatrix);
            }
        }

        // SILENT AIM
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3 headPos, localPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            headPos  = g_headPos;
            localPos = g_localPos;
        }
        if (!validPtr(h)) {
            std::this_thread::yield();
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = localPos;

        Vector3 dir = { headPos.x - origin.x, headPos.y - origin.y, headPos.z - origin.z };
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
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        g_local  = 0;
        g_target = 0;
        g_headPos = {};
        g_localPos = {};
    }
    {
        std::lock_guard<std::mutex> lk(s_magnetLock);
        s_basePos.clear();
    }
}

// Публичное API для меню
extern "C" void SetAimMagnet(bool e)          { g_magnetEnabled.store(e); }
extern "C" void SetAimMagnetStrength(float s) { g_magnetStrength.store(s); }
extern "C" void SetAimMagnetMaxDist(float d)  { g_magnetMaxDist.store(d); }
extern "C" void SetAimMagnetCamDown(float y)  { g_magnetCamDown.store(y); }
extern "C" bool GetAimMagnet()                { return g_magnetEnabled.load(); }

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
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    g_viewMatrix = GetViewMatrix(CameraMain(cachedMatch));

    Vector3 head = HeadPos(target);
    if (isZeroV3(head)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }
    head.y += kHeadCenterY;

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = aimPtr;
        g_local    = local;
        g_target   = target;
        g_headPos  = head;
        g_localPos = lPos;
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенный пинг
    {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        Vector3 dir = { head.x - origin.x, head.y - origin.y, head.z - origin.z };
        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
    }
}
