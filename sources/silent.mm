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

// Смещения
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // основная структура
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8; // необязательно, можно убрать

// Дополнительные структуры HitObjectInfo (если есть в вашей версии)
static constexpr uint64_t kPlayer_LastAimInfo2 = 0xDD0;
static constexpr uint64_t kPlayer_AimInfo3     = 0xA90;
static constexpr uint64_t kPlayer_AimInfo4     = 0xAA0;

// Глобальные данные для потока
static std::atomic<bool> g_HasData{false};
static uint64_t          g_PlayerPtr = 0;
static Vector3           g_TargetPos = {};
static Vector3           g_LocalPos  = {};

static std::thread       g_silentThread;
static std::atomic<bool> g_threadStarted{false};

// Получение позиции головы
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Фоновый поток: пишет направление с частотой ~40 кГц
static void SilentWorker() {
    const uintptr_t hitObjOffs[4] = { kPlayer_LastAimInfo, kPlayer_LastAimInfo2,
                                      kPlayer_AimInfo3, kPlayer_AimInfo4 };
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(25));
        if (!g_HasData.load(std::memory_order_acquire)) continue;

        uint64_t player = g_PlayerPtr;
        Vector3 target  = g_TargetPos;
        Vector3 local   = g_LocalPos;
        if (!player || (player < 0x10000000)) continue;

        for (int i = 0; i < 4; ++i) {
            uint64_t hitObj = ReadAddr<uint64_t>(player + hitObjOffs[i]);
            if (!isVaildPtr(hitObj)) continue;

            // Точка старта луча
            Vector3 origin = ReadAddr<Vector3>(hitObj + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = local;

            Vector3 diff  = { target.x - origin.x, target.y - origin.y, target.z - origin.z };
            float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
            if (lenSq <= 0.0001f) continue;

            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

            // Записываем направление
            WriteAddr<Vector3>(hitObj + kHit_RayDir, dir);
        }
    }
}

// Вызывается каждый кадр из renderESPWithBuffers
void RunSilentAim() {
    // Инициализируем поток при первом вызове
    if (!g_threadStarted.exchange(true)) {
        g_silentThread = std::thread(SilentWorker);
        g_silentThread.detach();
    }

    // Проверяем условия
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_HasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_HasData.store(false, std::memory_order_release);
        return;
    }

    // (Опционально) проверка оружия — можно убрать
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_HasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_HasData.store(false, std::memory_order_release);
        return;
    }

    // Обновляем данные для потока
    g_PlayerPtr = local;
    g_TargetPos = tPos;
    g_LocalPos  = HeadPos(local);
    g_HasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_HasData.store(false, std::memory_order_release);
    g_PlayerPtr = 0;
}
