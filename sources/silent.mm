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
extern bool     aimsilent1;

// OB54: Player слоты для GMPGMPFNMFP (HitObjectInfo)
static constexpr uint64_t kHitSlots[] = { 0xA90, 0xAA0, 0xDC8, 0xDD0 };

// GMPGMPFNMFP field offsets (подтверждено OB53+OB54 дампами)
static constexpr uint64_t kHit_HitCollider  = 0x20; // Collider
static constexpr uint64_t kHit_HitLocation  = 0x28; // Vector3
static constexpr uint64_t kHit_HitNormal    = 0x34; // Vector3
static constexpr uint64_t kHit_RayDir       = 0x40; // Vector3
static constexpr uint64_t kHit_StartPos     = 0x4C; // Vector3
static constexpr uint64_t kHit_Distance     = 0x5C; // float
static constexpr uint64_t kHit_HitGroup     = 0x64; // int (1=Head)
static constexpr uint64_t kHit_IgnoreHap    = 0x70; // bool
static constexpr uint64_t kHit_ViewBlocked  = 0x71; // bool
static constexpr uint64_t kHit_OrigStart    = 0x74; // Vector3
static constexpr uint64_t kHit_SpecialType  = 0x80; // short

// Player offsets
static constexpr uint64_t kPlayer_HeadCollider    = 0x6D0; // protected Collider NFDNMIOPILM (m_HeadCollider)
static constexpr uint64_t kPlayer_LockedAimCol    = 0x80;  // AttackableEntity.LockedAimingCollider backing field
static constexpr uint64_t kWpn_CostAmmo           = 0x7B8;

static std::atomic<bool>     g_hasData{false};
static std::atomic<bool>     g_started{false};
static std::atomic<uint64_t> g_target {0};
static std::atomic<uint64_t> g_local  {0};

static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void DoSubstitute(uint64_t local, uint64_t target) {
    // Читаем head collider врага
    uint64_t headCollider = ReadAddr<uint64_t>(target + kPlayer_HeadCollider);
    if (!isValidIOSPtr(headCollider)) return;

    // SetAimCollider: пишем LockedAimingCollider на localPlayer
    WriteAddr<uint64_t>(local + kPlayer_LockedAimCol, headCollider);

    // Позиция головы врага — свежая
    Vector3 headPos = HeadPos(target);
    if (headPos.x == 0.0f && headPos.y == 0.0f && headPos.z == 0.0f) return;
    headPos.y += 0.05f;

    Vector3 localPos = HeadPos(local);

    Vector3 diff = { headPos.x-localPos.x, headPos.y-localPos.y, headPos.z-localPos.z };
    float lenSq  = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
    if (lenSq <= 0.0001f) return;

    float   inv  = 1.0f / std::sqrt(lenSq);
    Vector3 dir  = { diff.x*inv, diff.y*inv, diff.z*inv };
    float   dist = std::sqrt(lenSq);

    // Пишем в все активные GMPGMPFNMFP слоты
    for (uint64_t slot : kHitSlots) {
        uint64_t h = ReadAddr<uint64_t>(local + slot);
        if (!isValidIOSPtr(h)) continue;

        WriteAddr<uint64_t>(h + kHit_HitCollider, headCollider); // HEAD collider
        WriteAddr<Vector3> (h + kHit_HitLocation,  headPos);
        WriteAddr<Vector3> (h + kHit_HitNormal,    headPos);
        WriteAddr<Vector3> (h + kHit_RayDir,       dir);
        WriteAddr<Vector3> (h + kHit_OrigStart,    localPos);
        WriteAddr<float>   (h + kHit_Distance,     dist);
        WriteAddr<int32_t> (h + kHit_HitGroup,     1);     // HEAD
        WriteAddr<bool>    (h + kHit_IgnoreHap,    false);
        WriteAddr<bool>    (h + kHit_ViewBlocked,  false);
        WriteAddr<int16_t> (h + kHit_SpecialType,  0);
        // StartPos не трогаем — пусть остаётся оригинальный muzzle
    }
}

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local  = g_local .load(std::memory_order_relaxed);
        uint64_t target = g_target.load(std::memory_order_relaxed);
        if (!isVaildPtr(local) || !isVaildPtr(target)) continue;

        DoSubstitute(local, target);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    g_local .store(local,  std::memory_order_relaxed);
    g_target.store(target, std::memory_order_relaxed);
    g_hasData.store(true,  std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    // Сбрасываем LockedAimingCollider
    uint64_t local = g_local.load(std::memory_order_relaxed);
    if (isVaildPtr(local))
        WriteAddr<uint64_t>(local + kPlayer_LockedAimCol, 0);
    g_local .store(0, std::memory_order_relaxed);
    g_target.store(0, std::memory_order_relaxed);
}
