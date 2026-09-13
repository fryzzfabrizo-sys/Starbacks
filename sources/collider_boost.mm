// collider_boost.mm
// Увеличение CapsuleCollider врага (радиус + высота).
// Самодостаточно: свой поток, сам читает префы, сам ищет матч.
// Дамп структуры пишется в /var/mobile/Documents/collider_dump.txt
//
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

// ─── Offsets из Player.cs ────────────────────────────────
static constexpr uint64_t kPlayer_CapsuleCollider = 0xAB0; // HOKDPBIKHGH
static constexpr uint64_t kPlayer_CapsuleHuman    = 0xAA8; // JCIOGODKHPP
static constexpr uint64_t kCapsuleHuman_Collider  = 0x28;

// ─── Целевые размеры ────────────────────────────────────
static constexpr float kBoostRadius = 0.55f;
static constexpr float kBoostHeight = 2.00f;

// ─── Границы «здоровых» значений ────────────────────────
static constexpr float kRadMin = 0.15f, kRadMax = 0.80f;
static constexpr float kHeiMin = 0.90f, kHeiMax = 2.50f;

// ─── Тайминги ───────────────────────────────────────────
static constexpr int kTickMs        = 60;   // период цикла буста
static constexpr int kDumpEveryNTicks = 3;  // как часто пытаться дампить

static std::atomic<bool> g_started{false};

// ─── Лог ─────────────────────────────────────────────────
static FILE        *g_logFp = nullptr;
static std::mutex   g_logLock;
static uint64_t     g_lastDumpedMatch = 0;
static int          g_dumpedCount     = 0;

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
                    "\n\n========== COLLIDER DUMP %04d-%02d-%02d %02d:%02d:%02d ==========\n",
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

static inline bool isSaneF(float v) { return isfinite(v) && fabsf(v) < 1000.0f; }

// ─── Достаём указатель коллайдера ────────────────────────
static uint64_t GetColliderPtr(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;

    uint64_t direct = ReadAddr<uint64_t>(pawn + kPlayer_CapsuleCollider);
    if (isVaildPtr(direct)) return direct;

    uint64_t human = ReadAddr<uint64_t>(pawn + kPlayer_CapsuleHuman);
    if (!isVaildPtr(human)) return 0;

    uint64_t c2 = ReadAddr<uint64_t>(human + kCapsuleHuman_Collider);
    return isVaildPtr(c2) ? c2 : 0;
}

// ─── Dump (один раз на матч, до 3 врагов) ────────────────
static void DumpOnce(uint64_t pawn, uint64_t match) {
    if (match != g_lastDumpedMatch) {
        g_lastDumpedMatch = match;
        g_dumpedCount = 0;
    }
    if (g_dumpedCount >= 3) return;
    g_dumpedCount++;

    uint64_t direct   = ReadAddr<uint64_t>(pawn + kPlayer_CapsuleCollider);
    uint64_t human    = ReadAddr<uint64_t>(pawn + kPlayer_CapsuleHuman);
    uint64_t humanCol = isVaildPtr(human)
                          ? ReadAddr<uint64_t>(human + kCapsuleHuman_Collider)
                          : 0;

    CLog(@"=== Dump #%d pawn=0x%llx ===", g_dumpedCount, pawn);
    CLog(@"   pawn+0xAB0      = 0x%llx", direct);
    CLog(@"   pawn+0xAA8      = 0x%llx", human);
    CLog(@"   +0xAA8->0x28    = 0x%llx", humanCol);

    uint64_t target = 0;
    const char *src = nullptr;
    if (isVaildPtr(direct))        { target = direct;   src = "0xAB0"; }
    else if (isVaildPtr(humanCol)) { target = humanCol; src = "Human+0x28"; }

    if (!target) {
        CLog(@"   → No valid collider pointer");
        return;
    }

    CLog(@"   Scanning %s @ 0x%llx:", src, target);
    for (uint64_t off = 0x10; off < 0x100; off += 4) {
        float v = ReadAddr<float>(target + off);
        if (isSaneF(v) && fabsf(v) > 0.0001f)
            CLog(@"      +0x%03llx = %.6f", off, v);
    }
    CLog(@"=== End Dump #%d ===", g_dumpedCount);
}

// ─── Пробуем записать пару (radius, height) ─────────────
static bool TryWritePair(uint64_t collider, uint64_t rOff, uint64_t hOff) {
    float r = ReadAddr<float>(collider + rOff);
    float h = ReadAddr<float>(collider + hOff);

    if (!isSaneF(r) || !isSaneF(h))   return false;
    if (r < kRadMin || r > kRadMax)   return false;
    if (h < kHeiMin || h > kHeiMax)   return false;
    if (h <= r * 1.5f)                return false;

    bool wrote = false;
    if (r < kBoostRadius) { WriteAddr<float>(collider + rOff, kBoostRadius); wrote = true; }
    if (h < kBoostHeight) { WriteAddr<float>(collider + hOff, kBoostHeight); wrote = true; }

    return wrote;
}

static void BoostOnePawn(uint64_t pawn) {
    uint64_t collider = GetColliderPtr(pawn);
    if (!isVaildPtr(collider)) return;

    static const uint64_t kPairs[][2] = {
        {0x34, 0x38},
        {0x3C, 0x40},
        {0x2C, 0x30},
        {0x30, 0x34},
        {0x38, 0x3C},
        {0x40, 0x44},
    };
    for (auto &p : kPairs)
        if (TryWritePair(collider, p[0], p[1])) return;

    for (uint64_t off = 0x18; off < 0x80; off += 4)
        if (TryWritePair(collider, off, off + 4)) return;
}

// ─── Воркер ─────────────────────────────────────────────
static void ColliderBoostWorker(void) {
    int tick = 0;
    uint64_t localMatch = 0;

    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kTickMs));
        tick++;

        // 1) Преф
        bool enabled = ESPPrefsBool(NSSENCRYPT("BoostHitbox"), NO);
        if (!enabled) { localMatch = 0; continue; }

        // 2) База
        if (Moudule_Base == (uint64_t)-1) {
            Moudule_Base = (uint64_t)GetGameModule_Base((char *)"FreeFire");
        }
        if (Moudule_Base == (uint64_t)-1) continue;

        // 3) Лобби?
        if (IsAtLobby(Moudule_Base)) { localMatch = 0; continue; }

        // 4) Матч
        uint64_t matchGame = getMatchGame(Moudule_Base);
        if (!isVaildPtr(matchGame)) continue;

        uint64_t match = getMatch(matchGame);
        if (!isVaildPtr(match)) continue;
        localMatch = match;

        // 5) Локальный игрок
        uint64_t myPawn = getLocalPlayer(match);
        if (!isVaildPtr(myPawn) || get_CurHP(myPawn) <= 0) continue;

        // 6) Словарь игроков
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

// ─── Автозапуск при загрузке dylib ──────────────────────
__attribute__((constructor))
static void ColliderBoostAutoInit(void) {
    ColliderBoostStart();
}
