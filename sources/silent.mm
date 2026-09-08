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

// iOS ARM64 OB54 оффсеты (из OB53 dump + сдвиг)
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // m_LastAimingInfoFromWeapon
static constexpr uint64_t kHit_RayDir         = 0x40;  // Vector3 RayDir (только это)
static constexpr uint64_t kHit_StartPos       = 0x4C;  // Vector3 StartPosition (читаем)
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

// Четыре слота HitObjectInfo в Player (OB54) — именно их мы будем перебирать
static constexpr uint64_t kHitObjOffs[4] = {
    0xDC8,  // AKFLHNOIHED   (основная стрельба)
    0xDD0,  // PJGMLPMAMGN   (новое в OB54)
    0xA90,  // GGKLDGMAFHN   (скилл/спецатака)
    0xAA0   // NFKMINKONNC   (скилл/спецатака, второй)
};

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_localPlayer = 0;   // теперь храним указатель на игрока
static Vector3           g_tPos        = {};
static Vector3           g_lPos        = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Поток: пишет RayDir во все 4 слота (но НЕ трогает разброс)
static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(8)); // 8 мкс – баланс
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local = g_localPlayer;
            tPos  = g_tPos;
            lPos  = g_lPos;
        }
        if (!isVaildPtr(local)) continue;

        // Перебираем все 4 слота
        for (int i = 0; i < 4; ++i) {
            uint64_t hitObj = ReadAddr<uint64_t>(local + kHitObjOffs[i]);
            if (!isVaildPtr(hitObj)) continue;

            // Читаем реальный StartPos из объекта
            Vector3 origin = ReadAddr<Vector3>(hitObj + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = lPos;

            Vector3 diff = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
            float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
            if (lenSq <= 0.0001f) continue;

            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };

            // Пишем ТОЛЬКО RayDir – без зануления разброса
            WriteAddr<Vector3>(hitObj + kHit_RayDir, dir);
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
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Гранаты и IceWall не тратят ammo
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Получаем позицию головы цели (без +0.05 Y)
    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // ---- НЕТ tPos.y += 0.05f ----

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_localPlayer = local;
        g_tPos        = tPos;
        g_lPos        = HeadPos(local); // fallback, если StartPos нулевой
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_localPlayer = 0;
}
