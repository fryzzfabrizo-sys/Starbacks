// collider_boost.mm
// Буст CapsuleCollider врага. Включается автоматически с Aim Magnet.

#import "collider_boost.h"
#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/offset.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"

#include <cmath>
#include <mutex>
#include <thread>
#include <chrono>
#include <atomic>
#import <Foundation/Foundation.h>

extern uint64_t Moudule_Base;
extern bool     aimMagnet;

// ─── Offset'ы (из дампа v3) ─────────────────────────────
static constexpr uint64_t kPlayer_CapsuleColliderManaged = 0xAB0;
static constexpr uint64_t kManaged_NativePtr             = 0x10;
static constexpr uint64_t kNative_RadiusOff              = 0x80;
static constexpr uint64_t kNative_HeightOff              = 0x84;

// ─── Размеры ────────────────────────────────────────────
static constexpr float kBoostRadius = 6.00f;
static constexpr float kBoostHeight = 12.00f;

static constexpr float kRadMin = 0.10f, kRadMax = 10.00f;
static constexpr float kHeiMin = 0.80f, kHeiMax = 20.00f;

static constexpr int kStartupDelayMs = 3000;
static constexpr int kTickMs         = 40;

static std::atomic<bool> g_started{false};

static inline bool saneF(float v) { return isfinite(v) && fabsf(v) < 1000.0f; }
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static void BoostOnePawn(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return;

    uint64_t managed = ReadAddr<uint64_t>(pawn + kPlayer_CapsuleColliderManaged);
    if (!validPtr(managed)) return;

    uint64_t native = ReadAddr<uint64_t>(managed + kManaged_NativePtr);
    if (!validPtr(native)) return;

    float r = ReadAddr<float>(native + kNative_RadiusOff);
    float h = ReadAddr<float>(native + kNative_HeightOff);

    if (!saneF(r) || !saneF(h))     return;
    if (r < kRadMin || r > kRadMax) return;
    if (h < kHeiMin || h > kHeiMax) return;

    if (r < kBoostRadius) WriteAddr<float>(native + kNative_RadiusOff, kBoostRadius);
    if (h < kBoostHeight) WriteAddr<float>(native + kNative_HeightOff, kBoostHeight);
}

static void ColliderBoostWorker(void) {
    std::this_thread::sleep_for(std::chrono::milliseconds(kStartupDelayMs));

    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kTickMs));

        if (!aimMagnet) continue;

        if (Moudule_Base == (uint64_t)-1) {
            Moudule_Base = (uint64_t)GetGameModule_Base((char *)"FreeFire");
        }
        if (Moudule_Base == (uint64_t)-1) continue;
        if (IsAtLobby(Moudule_Base)) continue;

        uint64_t matchGame = getMatchGame(Moudule_Base);
        if (!isVaildPtr(matchGame)) continue;

        uint64_t match = getMatch(matchGame);
        if (!isVaildPtr(match)) continue;

        uint64_t myPawn = getLocalPlayer(match);
        if (!isVaildPtr(myPawn) || get_CurHP(myPawn) <= 0) continue;

        uint64_t playerDict = ReadAddr<uint64_t>(match + kMatchPlayerDict);
        if (!isVaildPtr(playerDict)) continue;

        int      dictCount  = ReadAddr<int>(playerDict + kDictCount);
        uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
        if (!isVaildPtr(entriesArr)) continue;

        int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
        if (slotCap <= 0 || slotCap > 256 || dictCount <= 0) continue;

        const uint64_t base = entriesArr + kIl2CppArrayItems;

        for (int i = 0; i < slotCap; i++) {
            uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
            if (ReadAddr<int>(ent) == 0) continue;

            uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
            if (!isVaildPtr(pawn)) continue;
            if (isLocalTeamMate(myPawn, pawn)) continue;
            if (get_CurHP(pawn) <= 0) continue;

            BoostOnePawn(pawn);
        }
    }
}

void ColliderBoostStart(void) {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(ColliderBoostWorker).detach();
}

@interface _ColliderBoostBootstrap : NSObject @end
@implementation _ColliderBoostBootstrap
+ (void)load { ColliderBoostStart(); }
@end

__attribute__((constructor))
static void _collider_boost_ctor(void) {
    ColliderBoostStart();
}
