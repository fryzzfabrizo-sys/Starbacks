#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <thread>
#include <chrono>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::thread       g_silentThread;
static std::atomic<bool> g_silentRunning{false};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ─── Синхронная логика Silent Aim ────────────────────────────────
void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isVaildPtr(aimPtr)) {
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        return;
    }

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f) {
        origin = HeadPos(local);
    }

    Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
    float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
    if (lenSq <= 0.0001f) return;

    float   inv = 1.0f / std::sqrt(lenSq);
    Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

    // Записываем направление прямо в структуру прицеливания
    WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
}

// ─── Запуск потока с обновлением 1000 раз в секунду ─────────────
void InitSilentAimThread() {
    if (g_silentRunning.exchange(true)) {
        return; // уже работает
    }

    g_silentThread = std::thread([]() {
        while (g_silentRunning.load(std::memory_order_acquire)) {
            RunSilentAim();
            // Спим 1 мс → частота 1000 Гц. Этого хватит для любого темпа стрельбы.
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    g_silentThread.detach();
}

void StopSilentAimThread() {
    g_silentRunning.store(false, std::memory_order_release);
}
