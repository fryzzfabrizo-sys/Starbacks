// collider_boost.mm
// Увеличение CapsuleCollider врага.
// Offset'ы зафиксированы по дампу v3.
//
// Дамп: /var/mobile/Documents/collider_dump.txt
// Ключ префа:  "BoostHitbox"

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
#include <cstdio>
#include <cstdarg>
#import <Foundation/Foundation.h>

extern uint64_t Moudule_Base;
extern bool get_IsBot(uint64_t player);

// ─── Точные offset'ы (из дампа v3) ──────────────────────
static constexpr uint64_t kPlayer_CapsuleColliderManaged = 0xAB0; // pawn → managed CapsuleCollider
static constexpr uint64_t kManaged_NativePtr             = 0x10;  // managed → native Unity-объект
static constexpr uint64_t kNative_RadiusOff              = 0x80;  // native + 0x80 = radius
static constexpr uint64_t kNative_HeightOff              = 0x84;  // native + 0x84 = height

static constexpr float kBoostRadius = 3.00f;
static constexpr float kBoostHeight = 6.00f;

// Границы "здоровых" значений — защита от мусора
static constexpr float kRadMin = 0.10f, kRadMax = 4.00f;
static constexpr float kHeiMin = 0.80f, kHeiMax = 8.00f;

static constexpr int kStartupDelayMs = 3000;
static constexpr int kTickMs         = 40;

static std::atomic<bool> g_started{false};

// ─── Лог ─────────────────────────────────────────────────
static FILE        *g_logFp = nullptr;
static std::mutex   g_logLock;
static uint64_t     g_lastLoggedMatch = 0;
static int          g_loggedCount     = 0;

static void LogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir  = @"/var/mobile/Documents";
        NSString *path = [dir stringByAppendingPathComponent:@"collider_dump.txt"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        g_logFp = fopen(path.UTF8String, "a");
        if (g_logFp) {
            time_t t = time(NULL);
            struct tm *tmv = localtime(&t);
            fprintf(g_logFp,
                    "\n\n========== COLLIDER BOOST v4 %04d-%02d-%02d %02d:%02d:%02d ==========\n",
                    tmv->tm_year + 1900, tmv->tm_mon + 1, tmv->tm_mday,
                    tmv->tm_hour, tmv->tm_min, tmv->tm_sec);
            fflush(g_logFp);
        }
    });
}

static void CLog(NSString *fmt, ...) {
    LogInit();
    if (!g_logFp) return;
    std::lock_guard<std::mutex> lk(g_logLock);
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    fprintf(g_logFp, "%s\n", s.UTF8String);
    fflush(g_logFp);
}

static inline bool saneF(float v) { return isfinite(v) && fabsf(v) < 1000.0f; }
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

// ─── Буст одного pawn'а ─────────────────────────────────
static bool BoostOnePawn(uint64_t pawn, bool doLog) {
    if (!isVaildPtr(pawn)) return false;

    uint64_t managed = ReadAddr<uint64_t>(pawn + kPlayer_CapsuleColliderManaged);
    if (!validPtr(managed)) return false;

    uint64_t native = ReadAddr<uint64_t>(managed + kManaged_NativePtr);
    if (!validPtr(native)) return false;

    float r = ReadAddr<float>(native + kNative_RadiusOff);
    float h = ReadAddr<float>(native + kNative_HeightOff);

    if (!saneF(r) || !saneF(h))     return false;
    if (r < kRadMin || r > kRadMax) return false;
    if (h < kHeiMin || h > kHeiMax) return false;

    bool wrote = false;
    if (r < kBoostRadius) {
        WriteAddr<float>(native + kNative_RadiusOff, kBoostRadius);
        wrote = true;
    }
    if (h < kBoostHeight) {
        WriteAddr<float>(native + kNative_HeightOff, kBoostHeight);
        wrote = true;
    }

    if (doLog && wrote) {
        CLog(@"   [BOOST] pawn=0x%llx native=0x%llx  r %.4f→%.4f  h %.4f→%.4f",
             pawn, native, r, kBoostRadius, h, kBoostHeight);
    }
    return wrote;
}

// ─── Воркер ─────────────────────────────────────────────
static void ColliderBoostWorker(void) {
    std::this_thread::sleep_for(std::chrono::milliseconds(kStartupDelayMs));

    int tick = 0;

    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kTickMs));
        tick++;

        bool enabled = ESPPrefsBool(NSSENCRYPT("BoostHitbox"), NO);
        if (!enabled) continue;

        if (Moudule_Base == (uint64_t)-1) {
            Moudule_Base = (uint64_t)GetGameModule_Base((char *)"FreeFire");
        }
        if (Moudule_Base == (uint64_t)-1) continue;

        if (IsAtLobby(Moudule_Base)) continue;

        uint64_t matchGame = getMatchGame(Moudule_Base);
        if (!isVaildPtr(matchGame)) continue;

        uint64_t match = getMatch(matchGame);
        if (!isVaildPtr(match)) continue;

        if (match != g_lastLoggedMatch) {
            g_lastLoggedMatch = match;
            g_loggedCount     = 0;
            CLog(@"\n=== New match 0x%llx ===", match);
        }

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

        int boosted = 0;
        for (int i = 0; i < slotCap; i++) {
            uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
            if (ReadAddr<int>(ent) == 0) continue;

            uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
            if (!isVaildPtr(pawn)) continue;
            if (isLocalTeamMate(myPawn, pawn)) continue;
            if (get_CurHP(pawn) <= 0) continue;

            bool doLog = (g_loggedCount < 5);
            if (BoostOnePawn(pawn, doLog)) {
                if (doLog) g_loggedCount++;
                boosted++;
            }
        }

        if (tick % 150 == 0) {
            CLog(@"[tick %d] boosted=%d", tick, boosted);
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
