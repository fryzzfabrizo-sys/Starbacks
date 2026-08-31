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

// OB54 iOS 64-bit (подтверждено OB53 dump + txt impl)
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // GEGFCFDGGGP = m_LastAimingInfoFromWeapon
static constexpr uint64_t kHit_RayDir         = 0x40;  // NHKKHPLFMNG — raw direction (не нормализуем)
static constexpr uint64_t kHit_StartPos        = 0x4C;  // BOGOIAMJFDN — origin
static constexpr uint64_t kWpn_CostAmmo        = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr  = 0;
static uint64_t          g_local   = 0;
static uint64_t          g_target  = 0;

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

        uint64_t h, local, target;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h      = g_aimPtr;
            local  = g_local;
            target = g_target;
        }
        if (!isValidIOSPtr(h) || !isVaildPtr(target)) continue;

        // Позиция головы — читается каждую итерацию (важно при движении)
        Vector3 tPos = HeadPos(target);
        if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) continue;
        tPos.y += 0.05f;

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = HeadPos(local);

        // Raw вектор — НЕ нормализуем (как во всех рабочих impl)
        Vector3 dir = {
            tPos.x - origin.x,
            tPos.y - origin.y,
            tPos.z - origin.z
        };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
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
        g_aimPtr = 0;
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        return;
    }

    // Гранаты / IceWall
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        return;
    }

    // Перечитываем aimPtr каждый кадр — фикс второго матча
    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isValidIOSPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr  = aimPtr;
        g_local   = local;
        g_target  = target;
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr  = 0;
    g_local   = 0;
    g_target  = 0;
}
