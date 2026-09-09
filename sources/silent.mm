#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <pthread.h>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ======== Оффсеты ========
static constexpr uint64_t kHit_RayDir   = 0x40;
static constexpr uint64_t kHit_StartPos = 0x4C;
static constexpr uint64_t kHit_Scatter  = 0x5C;

// Четыре слота HitObjectInfo (OB54)
static constexpr uint64_t kHitObjOffs[4] = {
    0xDC8, 0xDD0, 0xA90, 0xAA0
};

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_localPlayer = 0;
static Vector3           g_tPos   = {};
static Vector3           g_lPos   = {};
static uint64_t          g_lastLocal = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ======== ПОТОК С МАКСИМАЛЬНЫМ ПРИОРИТЕТОМ ========
static void SilentWorker() {
    // Повышаем приоритет
    pthread_t thread = pthread_self();
    struct sched_param param;
    int policy;
    pthread_getschedparam(thread, &policy, &param);
    param.sched_priority = sched_get_priority_max(policy);
    pthread_setschedparam(thread, policy, &param);

    while (true) {
        // Минимальная задержка – для максимальной частоты
        std::this_thread::sleep_for(std::chrono::nanoseconds(1));

        // ПРОВЕРКА: если нет данных – пропускаем, но продолжаем цикл
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local = g_localPlayer;
            tPos  = g_tPos;
            lPos  = g_lPos;
        }
        if (!validPtr(local)) continue;

        // Перебираем все 4 слота
        for (int i = 0; i < 4; ++i) {
            uint64_t hitObj = ReadAddr<uint64_t>(local + kHitObjOffs[i]);
            if (!validPtr(hitObj)) continue;

            Vector3 origin = ReadAddr<Vector3>(hitObj + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = lPos;

            // ---- ПИШЕМ НЕНОРМАЛИЗОВАННЫЙ ВЕКТОР (diff) ----
            Vector3 diff = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
            WriteAddr<Vector3>(hitObj + kHit_RayDir, diff);
            // Зануляем разброс
            WriteAddr<float>(hitObj + kHit_Scatter, 0.0f);
        }
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

// ======== Основная функция, вызывается из esp.mm каждый кадр ========
void RunSilentAim() {
    InitSilentAimThread();

    // Если сайлент выключен или нет матча – останавливаем запись
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t local = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Сброс при смене матча
    if (local != g_lastLocal) {
        g_lastLocal = local;
        g_hasData.store(false, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lk(g_lock);
            g_localPlayer = 0;
        }
        return;
    }

    // ---- УБИРАЕМ ПРОВЕРКУ НА ГРАНАТЫ / ОРУЖИЕ ----
    // Теперь пишем всегда, даже для гранат

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_localPlayer = local;
        g_tPos        = tPos;
        g_lPos        = HeadPos(local); // fallback
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastLocal = 0;
    std::lock_guard<std::mutex> lk(g_lock);
    g_localPlayer = 0;
}
