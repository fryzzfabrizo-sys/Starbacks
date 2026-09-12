// SilentAim.mm
// Silent aim через ITransformNode головы (0x638) + предикция движения цели
// Все оффсеты — из offset.h

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ═══════════════════════════════════════════════════════════════════
//  🎯 РУЧНАЯ ПОДГОНКА (единственные константы, которые не из offset.h)
// ═══════════════════════════════════════════════════════════════════
//  Тонкая доводка прицела (обычно 0 — предикция сама всё делает)
static constexpr float kHeadXOffset = 0.0f;
static constexpr float kHeadYOffset = 0.10f;   // + выше / - ниже
static constexpr float kHeadZOffset = 0.0f;

//  Скорость пули. Чем МЕНЬШЕ — тем СИЛЬНЕЕ упреждение по бегущим.
//    Быстрое оружие (SMG/AR) : 250 … 300
//    Среднее                 : 180 … 220   ← рабочее
//    Снайперка / медленный   : 100 … 150
static constexpr float kBVR = 200.0f;
// ═══════════════════════════════════════════════════════════════════

// ─── Offsets (все из offset.h) ──────────────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;   // LastAimInfo_Ptr (iOS)
static constexpr uint64_t kHit_RayDir         = 0x40;    // Vector3 RayDir
static constexpr uint64_t kHit_StartPos       = 0x4C;    // Vector3 StartPos

static constexpr uint64_t kPlayer_HeadNode    = kHeadNode;        // 0x638
static constexpr uint64_t kBodyPart_TransNode = kBodyPartTransNode; // 0x10

// velocity chain A (короткая) — из offset.h
static constexpr uint64_t kPhysCCT_Off          = kPhysCCT;           // 0x200
static constexpr uint64_t kPhysCCT_Velocity_Off = kPhysCCT_Velocity;  // 0x17C

// velocity chain B (резерв) — из offset.h
static constexpr uint64_t kMyPhysXData_Off      = kMyPhysXData;       // 0x1B80
static constexpr uint64_t kPhxNpeononogeo_Off   = kPhxNpeononogeo;    // 0x20

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static Vector3           g_tVel      = {};
static uint64_t          g_lastMatch = 0;

// ─── Helpers ────────────────────────────────────────────────────────
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}

// Голова строго по оффсету: Player + 0x638 -> +0x10 -> Transform -> getPositionExt
static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};

    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};

    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};

    return getPositionExt(node);
}

// Скорость цели: сначала цепочка A (0x200 -> 0x17C), потом B (0x1B80 -> 0x20 -> 0x17C)
static Vector3 TargetVelocity(uint64_t pawn) {
    if (!validPtr(pawn)) return {};

    // chain A
    uint64_t cct = ReadAddr<uint64_t>(pawn + kPhysCCT_Off);
    if (validPtr(cct)) {
        Vector3 v = ReadAddr<Vector3>(cct + kPhysCCT_Velocity_Off);
        if (std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
            (v.x != 0.f || v.y != 0.f || v.z != 0.f)) {
            return v;
        }
    }

    // chain B (fallback)
    uint64_t phys = ReadAddr<uint64_t>(pawn + kMyPhysXData_Off);
    if (!validPtr(phys)) return {};
    cct = ReadAddr<uint64_t>(phys + kPhxNpeononogeo_Off);
    if (!validPtr(cct)) return {};
    return ReadAddr<Vector3>(cct + kPhysCCT_Velocity_Off);
}

// Финальное направление луча: (tPos - origin) + velocity * tFly + offsets
static Vector3 BuildRayDir(const Vector3& origin, const Vector3& tPos, const Vector3& tVel) {
    float dx   = tPos.x - origin.x;
    float dy   = tPos.y - origin.y;
    float dz   = tPos.z - origin.z;
    float dist = std::sqrt(dx*dx + dy*dy + dz*dz);

    float tFly = (kBVR > 1.0f) ? (dist / kBVR) : 0.0f;

    return Vector3{
        dx + tVel.x * tFly + kHeadXOffset,
        dy + tVel.y * tFly + kHeadYOffset,
        dz + tVel.z * tFly + kHeadZOffset
    };
}

// ─── Silent Worker ──────────────────────────────────────────────────
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos, tVel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            tVel = g_tVel;
        }

        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = BuildRayDir(origin, tPos, tVel);

        WriteAddr<Vector3>(h + kHit_RayDir, diff);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
    g_tPos   = {};
    g_tVel   = {};
}

// ─── Main ───────────────────────────────────────────────────────────
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
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

    if (!validPtr(local) || !validPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (!validVec(tPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tVel = TargetVelocity(target);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_tVel   = tVel;
    }
    g_hasData.store(true, std::memory_order_release);

    // мгновенная запись в кадре
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = BuildRayDir(origin, tPos, tVel);

    WriteAddr<Vector3>(aimPtr + kHit_RayDir, diffVR` ↓ (200 → );
}
