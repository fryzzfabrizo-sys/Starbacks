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
extern bool aimsilent1;

// HitObjectInfo (GMPGMPFNMFP) field offsets — подтверждено старым и новым дампом
// Пишем ТОЛЬКО в scalar/vector поля — НЕ трогаем pointer поля (0x18, 0x20)
// чтобы не крашить игру при разыменовании
static constexpr uint64_t kHitSlots[]     = { 0xA90, 0xAA0, 0xDC8, 0xDD0,
                                               0x15F0, 0x1760, 0x1A88 };
static constexpr uint64_t kHit_HitLoc    = 0x28; // Vector3 HitLocation
static constexpr uint64_t kHit_HitNorm   = 0x34; // Vector3 HitNormal
static constexpr uint64_t kHit_RayDir    = 0x40; // Vector3 RayDir
static constexpr uint64_t kHit_StartPos  = 0x4C; // Vector3 StartPosition
static constexpr uint64_t kHit_Distance  = 0x5C; // float   Distance
static constexpr uint64_t kHit_HitGroup  = 0x64; // int     HitGroup (1=Head)
static constexpr uint64_t kHit_IgnoreHap = 0x70; // bool    IgnoreHappens
static constexpr uint64_t kHit_ViewBlk   = 0x71; // bool    ViewBlocked
static constexpr uint64_t kHit_OrigStart = 0x74; // Vector3 OrigStartPosition
static constexpr uint64_t kHit_SpecType  = 0x80; // short   SpecialHitType

static constexpr uint64_t kWpn_CostAmmo  = 0x7B8; // bool m_CostAmmo

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_local = 0;
static Vector3           g_tPos  = {};
static Vector3           g_lPos  = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void WriteHit(uint64_t h, const Vector3& tPos, const Vector3& lPos) {
    Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
    if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
        origin = lPos;

    Vector3 diff  = { tPos.x-origin.x, tPos.y-origin.y, tPos.z-origin.z };
    float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
    if (lenSq <= 0.0001f) return;

    float   inv  = 1.0f / std::sqrt(lenSq);
    Vector3 dir  = { diff.x*inv, diff.y*inv, diff.z*inv };
    float   dist = std::sqrt(lenSq);

    // Только scalar/vector — никаких pointer полей (HitObject 0x18, HitCollider 0x20)
    WriteAddr<Vector3> (h + kHit_HitLoc,    tPos);
    WriteAddr<Vector3> (h + kHit_HitNorm,   tPos);
    WriteAddr<Vector3> (h + kHit_RayDir,    dir);
    WriteAddr<Vector3> (h + kHit_OrigStart, origin);
    WriteAddr<float>   (h + kHit_Distance,  dist);
    WriteAddr<int32_t> (h + kHit_HitGroup,  1);
    WriteAddr<bool>    (h + kHit_IgnoreHap, false);
    WriteAddr<bool>    (h + kHit_ViewBlk,   false);
    WriteAddr<int16_t> (h + kHit_SpecType,  0);
}

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local = g_local;
            tPos  = g_tPos;
            lPos  = g_lPos;
        }
        if (!isVaildPtr(local)) continue;

        for (uint64_t slot : kHitSlots) {
            uint64_t h = ReadAddr<uint64_t>(local + slot);
            if (!isVaildPtr(h)) continue;
            WriteHit(h, tPos, lPos);
        }
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
        std::lock_guard<std::mutex> lk(g_lock);
        g_local = 0;
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Гранаты и IceWall (HandCannonIceWall=19, Grenade=5) не тратят ammo → пропускаем
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_local = local;
        g_tPos  = tPos;
        g_lPos  = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}
