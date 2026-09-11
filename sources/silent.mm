#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <thread>
#include <cstring>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

static constexpr float kHeadCenterY = 0.055f;
static constexpr uint64_t kTransitionCooldownMs = 500;

static std::atomic<uint64_t> g_transitionTick{0};
static uint64_t              g_lastMatch = 0;
static uint64_t              g_lastHandledAimPtr = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}
static inline uint64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

void ResetSilentAim() {
    g_transitionTick.store(nowMs(), std::memory_order_release);
    g_lastMatch = 0;
    g_lastHandledAimPtr = 0;
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — мгновенный снапшот направления в момент выстрела
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        ResetSilentAim();
        return;
    }

    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        return;
    }

    uint64_t tTick = g_transitionTick.load(std::memory_order_relaxed);
    if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_lastHandledAimPtr = 0;
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_lastHandledAimPtr = 0;
        return;
    }

    // Если это новый выстрел/патрон — делаем моментальный снапшот без динамического трекинга врага
    if (aimPtr != g_lastHandledAimPtr) {
        Vector3 head = HeadPos(target);
        if (isZeroV3(head)) return;

        head.y += kHeadCenterY;
        Vector3 lPos = HeadPos(local);

        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        Vector3 dir = {
            head.x - origin.x,
            head.y - origin.y,
            head.z - origin.z
        };

        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
        g_lastHandledAimPtr = aimPtr;
    }
}
