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

// GMPGMPFNMFP offsets (из dump.cs)
static constexpr uint64_t kHitSlots[]       = { 0xDC8, 0xDD0, 0xA90, 0xAA0 };
static constexpr uint64_t kHit_RayDir       = 0x40; // Vector3 IKDEGKIICJP — direction
static constexpr uint64_t kHit_HitLocation  = 0x28; // Vector3 MBGBCLNJOMK — hit pos
static constexpr uint64_t kHit_HitNormal    = 0x34; // Vector3 DGFLGBEOGPG — normal
static constexpr uint64_t kHit_StartPos     = 0x4C; // Vector3 LMAEGPEAECO — origin
static constexpr uint64_t kHit_Distance     = 0x5C; // float   PGCPFOAJHBM — dist
static constexpr uint64_t kHit_HitGroup     = 0x64; // int     FLCLOHCBJEI — 1=Head
static constexpr uint64_t kHit_IgnoreHap    = 0x70; // bool    DEDOKPCAHAC
static constexpr uint64_t kHit_ViewBlocked  = 0x71; // bool    GGJOADOBLID
static constexpr uint64_t kHit_OrigStart    = 0x74; // Vector3 KPEICEMCHIF
static constexpr uint64_t kHit_SpecialType  = 0x80; // short   LNOIFBAFGOK

// Enemy body collider
static constexpr uint64_t kEnemy_Collider   = 0x6D0; // protected Collider NFDNMIOPILM

// m_CostAmmo на оружии (FDAEPHMIEPC) — false у гранат и IceWall
static constexpr uint64_t kWpn_CostAmmo     = 0x7B8;

static std::mutex      g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_threadStarted{false};

static uint64_t g_localPlayer  = 0;
static uint64_t g_enemyCollider = 0;
static Vector3  g_targetPos    = {};
static Vector3  g_localPos     = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local, ecol;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local = g_localPlayer;
            ecol  = g_enemyCollider;
            tPos  = g_targetPos;
            lPos  = g_localPos;
        }
        if (!isVaildPtr(local)) continue;

        for (uint64_t slot : kHitSlots) {
            uint64_t h = ReadAddr<uint64_t>(local + slot);
            if (!isVaildPtr(h)) continue;

            Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = lPos;

            Vector3 diff = { tPos.x - origin.x,
                             tPos.y - origin.y,
                             tPos.z - origin.z };

            float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
            if (lenSq <= 0.0001f) continue;

            float inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };
            float   dist = std::sqrt(lenSq);

            // Перенаправляем пулю — полный набор полей
            WriteAddr<Vector3>  (h + kHit_RayDir,      dir);
            WriteAddr<Vector3>  (h + kHit_HitLocation,  tPos);
            WriteAddr<Vector3>  (h + kHit_HitNormal,    tPos);
            WriteAddr<Vector3>  (h + kHit_OrigStart,    origin);
            WriteAddr<float>    (h + kHit_Distance,     dist);
            WriteAddr<int32_t>  (h + kHit_HitGroup,     1);
            WriteAddr<bool>     (h + kHit_IgnoreHap,    false);
            WriteAddr<bool>     (h + kHit_ViewBlocked,  false);
            WriteAddr<int16_t>  (h + kHit_SpecialType,  0);
            if (isVaildPtr(ecol))
                WriteAddr<uint64_t>(h + 0x20, ecol); // HitCollider
            // 0x5C НЕ пишем 0.0f — ломает дистанцию и крашит
        }
    }
}

void InitSilentAimThread() {
    bool expected = false;
    if (g_threadStarted.compare_exchange_strong(expected, true))
        std::thread(SilentWorker).detach();
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lk(g_lock);
        g_localPlayer = 0;
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Проверка оружия — гранаты и IceWall не тратят ammo
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
        g_localPlayer   = local;
        g_targetPos     = tPos;
        g_localPos      = HeadPos(local);
        g_enemyCollider = ReadAddr<uint64_t>(target + kEnemy_Collider);
    }
    g_hasData.store(true, std::memory_order_release);
}
