#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <thread>
#include <chrono>
#include <mutex>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// Все структуры HitObjectInfo, через которые могут идти пули
static constexpr uint64_t kHitObjectOffsets[4] = {0xDC8, 0xDD0, 0xA90, 0xAA0};
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_Scatter        = 0x5C; // разброс, обязательно занулять
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_PlayerPtr = 0; // local player (не aimPtr!)
static Vector3           g_TargetPos = {};
static Vector3           g_LocalPos  = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Фоновый поток: пишет направление и зануляет разброс во всех структурах
static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(17));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t player;
        Vector3  targetPos, localPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            player    = g_PlayerPtr;
            targetPos = g_TargetPos;
            localPos  = g_LocalPos;
        }
        if (!isVaildPtr(player)) continue;

        // Проходим по всем четырём структурам
        for (int i = 0; i < 4; i++) {
            uint64_t hitObj = ReadAddr<uint64_t>(player + kHitObjectOffsets[i]);
            if (!isVaildPtr(hitObj)) continue;

            // Читаем StartPos; если нулевой — берём позицию игрока
            Vector3 origin = ReadAddr<Vector3>(hitObj + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = localPos;

            Vector3 diff  = { targetPos.x - origin.x, targetPos.y - origin.y, targetPos.z - origin.z };
            float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
            if (lenSq <= 0.0001f) continue;

            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

            // Записываем направление
            WriteAddr<Vector3>(hitObj + kHit_RayDir, dir);

            // Обнуляем разброс — иначе игра добавит случайное отклонение
            WriteAddr<float>(hitObj + kHit_Scatter, 0.0f);
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

    // Проверка оружия (гранаты, лёд и т.п.)
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

    // Небольшая поправка по Y для точного попадания в голову
    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_PlayerPtr = local;
        g_TargetPos = tPos;
        g_LocalPos  = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_PlayerPtr = 0;
}
