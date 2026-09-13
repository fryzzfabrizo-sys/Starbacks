// collider_boost.mm
// Увеличение CapsuleCollider врага.
// Самодостаточно, автозапуск через +load и constructor.
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
#include <vector>
#include <cstdio>
#include <cstdarg>
#import <Foundation/Foundation.h>

extern uint64_t Moudule_Base;
extern bool get_IsBot(uint64_t player); // из esp.mm

// ─── Кандидаты offset'ов коллайдера в pawn ──────────────
static constexpr uint64_t kCand_CapsuleColliderA = 0xAB0;
static constexpr uint64_t kCand_CapsuleColliderB = 0xAA8;
static constexpr uint64_t kCand_CapsuleColliderC = 0xAC0;
static constexpr uint64_t kCand_CapsuleColliderD = 0xA98;

// ─── Целевые размеры ────────────────────────────────────
static constexpr float kBoostRadius = 0.55f;
static constexpr float kBoostHeight = 2.00f;

// Границы "здоровых" значений радиуса/высоты капсулы
static constexpr float kRadMin = 0.10f, kRadMax = 0.90f;
static constexpr float kHeiMin = 0.80f, kHeiMax = 2.60f;

static constexpr int kStartupDelayMs  = 3000;
static constexpr int kTickMs          = 60;
static constexpr int kDumpEveryNTicks = 3;

static std::atomic<bool> g_started{false};

// ─── Runtime-найденные offset'ы ─────────────────────────
static std::atomic<uint64_t> g_foundColliderOff{0};
static std::atomic<uint64_t> g_foundRadiusOff{0};
static std::atomic<uint64_t> g_foundHeightOff{0};

// ─── Лог ─────────────────────────────────────────────────
static FILE        *g_logFp = nullptr;
static std::mutex   g_logLock;
static uint64_t     g_lastDumpedMatch = 0;
static int          g_dumpedCount     = 0;

static uint64_t g_dumpedPawns[8] = {0};
static int      g_dumpedPawnCount = 0;

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
                    "\n\n========== COLLIDER DUMP v3 %04d-%02d-%02d %02d:%02d:%02d ==========\n",
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

static bool AlreadyDumpedPawn(uint64_t pawn) {
    for (int i = 0; i < g_dumpedPawnCount; i++)
        if (g_dumpedPawns[i] == pawn) return true;
    return false;
}

static void MarkDumpedPawn(uint64_t pawn) {
    if (g_dumpedPawnCount < 8)
        g_dumpedPawns[g_dumpedPawnCount++] = pawn;
}

// ─── Поиск пары (radius, height) в блоке памяти ─────────
static uint64_t ScanForRadiusHeightPair(uint64_t base, uint64_t start, uint64_t end,
                                        float *outR, float *outH) {
    for (uint64_t off = start; off + 4 < end; off += 4) {
        float r = ReadAddr<float>(base + off);
        if (!saneF(r)) continue;
        if (r < kRadMin || r > kRadMax) continue;

        for (uint64_t hOff = off + 4; hOff <= off + 0x20 && hOff + 4 < end; hOff += 4) {
            float h = ReadAddr<float>(base + hOff);
            if (!saneF(h)) continue;
            if (h < kHeiMin || h > kHeiMax) continue;
            if (h <= r * 1.5f) continue;
            *outR = r;
            *outH = h;
            return off;
        }
    }
    return 0;
}

// ─── Сканируем один объект-кандидат ─────────────────────
static void ScanCandidateObject(uint64_t pawn, uint64_t offsetInPawn, const char *name) {
    uint64_t ptr = ReadAddr<uint64_t>(pawn + offsetInPawn);
    if (!validPtr(ptr)) return;

    CLog(@"   [%s] pawn+0x%llx -> 0x%llx", name, offsetInPawn, ptr);

    // managed
    float r1 = 0, h1 = 0;
    uint64_t ro1 = ScanForRadiusHeightPair(ptr, 0x10, 0x200, &r1, &h1);
    if (ro1) {
        CLog(@"      managed: radius @ +0x%llx = %.4f, height @ ~+0x%llx = %.4f",
             ro1, r1, ro1 + 4, h1);
    }

    // native ptr по стандартным смещениям
    for (uint64_t nOff = 0x10; nOff <= 0x20; nOff += 8) {
        uint64_t native = ReadAddr<uint64_t>(ptr + nOff);
        if (!validPtr(native)) continue;

        float r2 = 0, h2 = 0;
        uint64_t ro2 = ScanForRadiusHeightPair(native, 0x10, 0x200, &r2, &h2);
        if (ro2) {
            CLog(@"      native@managed+0x%llx (0x%llx): radius @ +0x%llx = %.4f, height @ ~+0x%llx = %.4f",
                 nOff, native, ro2, r2, ro2 + 4, h2);
        }
    }
}

// ─── Широкий скан самого pawn'а ─────────────────────────
static void WideScanPawn(uint64_t pawn) {
    CLog(@"   Wide scan pawn (0x80..0xA00):");
    for (uint64_t off = 0x80; off + 0x20 < 0xA00; off += 4) {
        float r = ReadAddr<float>(pawn + off);
        if (!saneF(r)) continue;
        if (r < kRadMin || r > kRadMax) continue;

        for (uint64_t hOff = off + 4; hOff <= off + 0x20; hOff += 4) {
            float h = ReadAddr<float>(pawn + hOff);
            if (!saneF(h)) continue;
            if (h < kHeiMin || h > kHeiMax) continue;
            if (h <= r * 1.5f) continue;
            CLog(@"      pawn+0x%03llx r=%.4f, pawn+0x%03llx h=%.4f", off, r, hOff, h);
            break;
        }
    }
}

// ─── Широкий скан указателей в pawn'е ───────────────────
static void WideScanPointers(uint64_t pawn) {
    CLog(@"   Wide scan pointers (0x80..0xA00):");
    for (uint64_t off = 0x80; off + 8 < 0xA00; off += 8) {
        uint64_t ptr = ReadAddr<uint64_t>(pawn + off);
        if (!validPtr(ptr)) continue;

        uint64_t klass   = ReadAddr<uint64_t>(ptr);
        uint64_t monitor = ReadAddr<uint64_t>(ptr + 0x8);
        if (!validPtr(klass)) continue;
        if (monitor != 0 && !validPtr(monitor)) continue;

        float r = 0, h = 0;
        uint64_t ro = ScanForRadiusHeightPair(ptr, 0x10, 0x180, &r, &h);
        if (ro) {
            CLog(@"      ptr@pawn+0x%03llx -> 0x%llx (klass=0x%llx): r@+0x%llx=%.4f h@~+0x%llx=%.4f",
                 off, ptr, klass, ro, r, ro + 4, h);
        }
    }
}

// ─── Дамп одного pawn'а ─────────────────────────────────
static void DumpOnce(uint64_t pawn, uint64_t match) {
    if (match != g_lastDumpedMatch) {
        g_lastDumpedMatch = match;
        g_dumpedCount     = 0;
        g_dumpedPawnCount = 0;
        for (int i = 0; i < 8; i++) g_dumpedPawns[i] = 0;
    }
    if (g_dumpedCount >= 3) return;
    if (AlreadyDumpedPawn(pawn)) return;
    MarkDumpedPawn(pawn);
    g_dumpedCount++;

    int  hp  = get_CurHP(pawn);
    bool bot = get_IsBot(pawn);

    CLog(@"\n=== Dump #%d pawn=0x%llx hp=%d isBot=%d ===",
         g_dumpedCount, pawn, hp, bot ? 1 : 0);

    ScanCandidateObject(pawn, kCand_CapsuleColliderA, "cand 0xAB0");
    ScanCandidateObject(pawn, kCand_CapsuleColliderB, "cand 0xAA8");
    ScanCandidateObject(pawn, kCand_CapsuleColliderC, "cand 0xAC0");
    ScanCandidateObject(pawn, kCand_CapsuleColliderD, "cand 0xA98");

    WideScanPawn(pawn);
    WideScanPointers(pawn);

    CLog(@"=== End Dump #%d ===\n", g_dumpedCount);
}

// ─── Буст ───────────────────────────────────────────────
static bool TryWritePair(uint64_t collider, uint64_t rOff, uint64_t hOff) {
    float r = ReadAddr<float>(collider + rOff);
    float h = ReadAddr<float>(collider + hOff);

    if (!saneF(r) || !saneF(h))     return false;
    if (r < kRadMin || r > kRadMax) return false;
    if (h < kHeiMin || h > kHeiMax) return false;
    if (h <= r * 1.5f)              return false;

    bool wrote = false;
    if (r < kBoostRadius) { WriteAddr<float>(collider + rOff, kBoostRadius); wrote = true; }
    if (h < kBoostHeight) { WriteAddr<float>(collider + hOff, kBoostHeight); wrote = true; }
    return wrote;
}

static void BoostOnePawn(uint64_t pawn) {
    uint64_t cOff = g_foundColliderOff.load(std::memory_order_acquire);
    uint64_t rOff = g_foundRadiusOff.load(std::memory_order_acquire);
    uint64_t hOff = g_foundHeightOff.load(std::memory_order_acquire);

    if (cOff && rOff && hOff) {
        uint64_t c = ReadAddr<uint64_t>(pawn + cOff);
        if (validPtr(c)) {
            TryWritePair(c, rOff, hOff);
            return;
        }
    }

    static const uint64_t kCOffs[] = {
        kCand_CapsuleColliderA, kCand_CapsuleColliderB,
        kCand_CapsuleColliderC, kCand_CapsuleColliderD
    };
    for (uint64_t co : kCOffs) {
        uint64_t c = ReadAddr<uint64_t>(pawn + co);
        if (!validPtr(c)) continue;

        for (uint64_t off = 0x18; off < 0x180; off += 4) {
            if (TryWritePair(c, off, off + 4)) {
                g_foundColliderOff.store(co,    std::memory_order_release);
                g_foundRadiusOff.store(off,     std::memory_order_release);
                g_foundHeightOff.store(off + 4, std::memory_order_release);
                return;
            }
        }
    }
}

// ─── Воркер ─────────────────────────────────────────────
static void ColliderBoostWorker(void) {
    std::this_thread::sleep_for(std::chrono::milliseconds(kStartupDelayMs));

    int tick = 0;
    uint64_t localMatch = 0;

    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kTickMs));
        tick++;

        bool enabled = ESPPrefsBool(NSSENCRYPT("BoostHitbox"), NO);
        if (!enabled) { localMatch = 0; continue; }

        if (Moudule_Base == (uint64_t)-1) {
            Moudule_Base = (uint64_t)GetGameModule_Base((char *)"FreeFire");
        }
        if (Moudule_Base == (uint64_t)-1) continue;

        if (IsAtLobby(Moudule_Base)) { localMatch = 0; continue; }

        uint64_t matchGame = getMatchGame(Moudule_Base);
        if (!isVaildPtr(matchGame)) continue;

        uint64_t match = getMatch(matchGame);
        if (!isVaildPtr(match)) continue;
        localMatch = match;

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

            if ((tick % kDumpEveryNTicks) == 0)
                DumpOnce(pawn, localMatch);

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
