#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#import "kexploit/physmem.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// OB54 iOS 64-bit (подтверждено всеми дампами)
static constexpr uint64_t kAimInfoSlots[] = { 0xDC8, 0xDD0 };
static constexpr uint64_t kHit_RayDir     = 0x40;  // RAW vector
static constexpr uint64_t kHit_StartPos   = 0x4C;
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
    // Пытаемся инициализировать kernel r/w при старте треда
    bool krw = physmem_init();

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

        // Свежая позиция головы каждую итерацию
        Vector3 tPos = HeadPos(target);
        if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) continue;
        tPos.y += 0.05f;

        for (uint64_t slot : kAimInfoSlots) {
            uint64_t h = ReadAddr<uint64_t>(local + slot);
            if (!isValidIOSPtr(h)) continue;

            Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = HeadPos(local);

            // RAW direction — не нормализуем
            Vector3 dir = {
                tPos.x - origin.x,
                tPos.y - origin.y,
                tPos.z - origin.z
            };

            uint64_t rayDirAddr = h + kHit_RayDir;

            if (krw && physmem_is_ready()) {
                // FAST PATH: физическая память (~10ns)
                // Пишем в физически маппированную страницу напрямую
                physmem_write(rayDirAddr, &dir, sizeof(Vector3));
            } else {
                // FALLBACK: mach_vm_write (~30µs)
                WriteAddr<Vector3>(rayDirAddr, dir);
            }
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
