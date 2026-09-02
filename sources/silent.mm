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

// Все 4 слота HitObjectInfo (обычный FF, MaxGame, скиллы)
static constexpr uint64_t kAimInfoSlots[] = { 0xDC8, 0xDD0, 0xA90, 0xAA0 };

// HitObjectInfo field offsets
static constexpr uint64_t kHit_HitLocation = 0x28;
static constexpr uint64_t kHit_RayDir      = 0x40; // RAW, без нормализации
static constexpr uint64_t kHit_StartPos    = 0x4C;
static constexpr uint64_t kHit_Scatter     = 0x5C; // разброс — обязательно занулить

static constexpr uint64_t kWpn_CostAmmo   = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_local  = 0;
static uint64_t          g_target = 0;

static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local, target;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local  = g_local;
            target = g_target;
        }
        if (!isVaildPtr(local) || !isVaildPtr(target)) continue;

        Vector3 tPos = HeadPos(target);
        if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) continue;
        tPos.y += 0.05f;

        // Пишем во все 4 слота
        for (uint64_t slot : kAimInfoSlots) {
            uint64_t h = ReadAddr<uint64_t>(local + slot);
            if (!isValidIOSPtr(h)) continue;

            Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = HeadPos(local);

            // RAW вектор — НЕ нормализуем
            Vector3 dir = {
                tPos.x - origin.x,
                tPos.y - origin.y,
                tPos.z - origin.z
            };

            // Пишем направление и позицию попадания
            WriteAddr<Vector3>(h + kHit_RayDir,      dir);
            WriteAddr<Vector3>(h + kHit_HitLocation, tPos);

            // Обнуляем разброс (scatter) — иначе пули разлетятся
            WriteAddr<float>(h + kHit_Scatter, 0.0f);
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
        g_local = g_target = 0;
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lk(g_lock);
        g_local = g_target = 0;
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lk(g_lock);
        g_local = g_target = 0;
        return;
    }

    // Валидируем хотя бы один слот
    bool anyValid = false;
    for (uint64_t slot : kAimInfoSlots) {
        uint64_t h = ReadAddr<uint64_t>(local + slot);
        if (isValidIOSPtr(h)) { anyValid = true; break; }
    }
    if (!anyValid) {
        g_hasData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lk(g_lock);
        g_local = g_target = 0;
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_local  = local;
        g_target = target;
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_local = g_target = 0;
}
