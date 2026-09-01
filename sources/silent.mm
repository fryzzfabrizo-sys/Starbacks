#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <chrono>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kHitSlots[]     = { 0xA90, 0xAA0, 0xDC8, 0xDD0,
                                               0x15F0, 0x1760, 0x1A88 };
static constexpr uint64_t kHit_HitGroup   = 0x64;
static constexpr uint64_t kHit_ViewBlocked = 0x71;
static constexpr uint64_t kHit_IgnoreHap  = 0x70;
static constexpr uint64_t kWpn_CostAmmo   = 0x7B8;

static std::atomic<bool>     g_hasData{false};
static std::atomic<bool>     g_started{false};
static std::atomic<uint64_t> g_local{0};

static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local = g_local.load(std::memory_order_relaxed);
        if (!isVaildPtr(local)) continue;

        for (uint64_t slot : kHitSlots) {
            uint64_t h = ReadAddr<uint64_t>(local + slot);
            if (!isValidIOSPtr(h)) continue;
            WriteAddr<int32_t>(h + kHit_HitGroup,    1);
            WriteAddr<bool>   (h + kHit_ViewBlocked,  false);
            WriteAddr<bool>   (h + kHit_IgnoreHap,   false);
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
        g_local.store(0, std::memory_order_relaxed);
        return;
    }

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local)) {
        g_hasData.store(false, std::memory_order_release);
        g_local.store(0, std::memory_order_relaxed);
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        g_local.store(0, std::memory_order_relaxed);
        return;
    }

    g_local.store(local, std::memory_order_relaxed);
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_local.store(0, std::memory_order_relaxed);
}
