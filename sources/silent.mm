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

// OB54 оффсеты (подтверждено из Offsets.hpp + OB53/OB54 дампов)
// m_LastAimingInfoFromWeapon = MADMMIICBNN GEGFCFDGGGP
// OB53: 0xD78 → OB54: 0xDC8 (сдвиг +0x50)
static constexpr uint64_t kPlayer_AimInfo  = 0xDC8; // m_LastAimingInfoFromWeapon ptr
static constexpr uint64_t kHit_HitLocation = 0x28;  // Vector3 HitLocation (GAMMEIDKJHK)
static constexpr uint64_t kHit_RayDir      = 0x40;  // Vector3 RayDir (NHKKHPLFMNG)
static constexpr uint64_t kHit_StartPos    = 0x4C;  // Vector3 StartPosition (BOGOIAMJFDN)
static constexpr uint64_t kWpn_CostAmmo    = 0x7B8; // bool m_CostAmmo

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimInfoPtr = 0;
static Vector3           g_targetPos  = {};
static Vector3           g_localPos   = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void DoWrite(uint64_t h, const Vector3& tPos, const Vector3& lPos) {
    // Читаем StartPos из объекта (позиция дула)
    Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
    if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
        origin = lPos;

    Vector3 diff  = { tPos.x-origin.x, tPos.y-origin.y, tPos.z-origin.z };
    float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
    if (lenSq <= 0.0001f) return;

    float   inv = 1.0f / std::sqrt(lenSq);
    Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };

    // Пишем RayDir и HitLocation — только Vector3, без pointer полей
    WriteAddr<Vector3>(h + kHit_RayDir,      dir);
    WriteAddr<Vector3>(h + kHit_HitLocation, tPos);
}

// Tight loop как в Silent.cpp — пишем непрерывно пока окно открыто
static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t h;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimInfoPtr;
            tPos = g_targetPos;
            lPos = g_localPos;
        }
        if (!isVaildPtr(h)) continue;
        DoWrite(h, tPos, lPos);
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

    // IceWall + гранаты не тратят ammo → пропускаем
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Читаем m_LastAimingInfoFromWeapon pointer
    uint64_t aimInfoPtr = ReadAddr<uint64_t>(local + kPlayer_AimInfo);
    if (!isVaildPtr(aimInfoPtr)) {
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
        g_aimInfoPtr = aimInfoPtr;
        g_targetPos  = tPos;
        g_localPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimInfoPtr = 0;
}
