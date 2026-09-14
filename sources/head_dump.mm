// head_dump.mm
// Разовый дамп структуры головы врага.
// Пишет /var/mobile/Documents/head_dump.txt

#import "head_dump.h"
#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"

#include <mutex>
#include <thread>
#include <chrono>
#include <atomic>
#include <cstdio>
#include <cstdarg>
#import <Foundation/Foundation.h>

extern uint64_t Moudule_Base;
extern bool     aimMagnet;

static std::atomic<bool> g_started{false};
static FILE        *g_logFp = nullptr;
static std::mutex   g_logLock;

static void LogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir  = @"/var/mobile/Documents";
        NSString *path = [dir stringByAppendingPathComponent:@"head_dump.txt"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        g_logFp = fopen(path.UTF8String, "a");
    });
}

static void HLog(NSString *fmt, ...) {
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

static inline bool isSaneF(float v) { return isfinite(v) && fabsf(v) < 10000.0f; }
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static void DumpPawn(uint64_t pawn, int index) {
    HLog(@"\n=== Pawn #%d 0x%llx ===", index, pawn);

    // 1) Что лежит по offset'ам, похожим на голову
    uint64_t candidates[] = { 0x638, 0x660, 0x668, 0x630, 0x628, 0x640 };
    const char *names[]   = { "HeadNode(0x638)", "RootNode(0x660)", "0x668", "0x630", "0x628", "0x640" };

    for (int i = 0; i < 6; i++) {
        uint64_t ptr = ReadAddr<uint64_t>(pawn + candidates[i]);
        if (!validPtr(ptr)) {
            HLog(@"   %s -> 0x%llx (invalid)", names[i], ptr);
            continue;
        }

        HLog(@"   %s -> 0x%llx", names[i], ptr);

        // Проверим цепочку: ptr -> +0x10 -> +0x10 -> +0x38 (matrix) -> +0x90 = position
        uint64_t p1 = ReadAddr<uint64_t>(ptr + 0x10);
        if (validPtr(p1)) {
            HLog(@"      +0x10 -> 0x%llx", p1);

            uint64_t p2 = ReadAddr<uint64_t>(p1 + 0x10);
            if (validPtr(p2)) {
                HLog(@"      +0x10+0x10 -> 0x%llx", p2);

                uint64_t mat = ReadAddr<uint64_t>(p2 + 0x38);
                if (validPtr(mat)) {
                    HLog(@"      +0x38 (matrix) -> 0x%llx", mat);
                    Vector3 pos = ReadAddr<Vector3>(mat + 0x90);
                    HLog(@"      matrix+0x90 pos = (%.3f, %.3f, %.3f)", pos.x, pos.y, pos.z);
                }

                uint64_t trans = ReadAddr<uint64_t>(p1 + 0x18);
                if (validPtr(trans)) {
                    Vector3 pos2 = ReadAddr<Vector3>(trans + 0x90);
                    if (isSaneF(pos2.x) && isSaneF(pos2.y) && isSaneF(pos2.z))
                        HLog(@"      +0x10+0x18 (trans)+0x90 = (%.3f, %.3f, %.3f)", pos2.x, pos2.y, pos2.z);
                }

                // Пробуем читать позицию через getPositionExt
                Vector3 posExt = getPositionExt(p1);
                if (isSaneF(posExt.x) && isSaneF(posExt.y) && isSaneF(posExt.z) && !(posExt.x==0&&posExt.y==0&&posExt.z==0))
                    HLog(@"      getPositionExt(+0x10) = (%.3f, %.3f, %.3f)", posExt.x, posExt.y, posExt.z);
            }
        }

        // Сканируем первые байты на предмет вектора позиции (x,y,z каждый в разумных пределах)
        HLog(@"   scan for vec3 in ptr+0x10..0x200:");
        for (uint64_t off = 0x10; off < 0x200; off += 4) {
            float x = ReadAddr<float>(ptr + off);
            float y = ReadAddr<float>(ptr + off + 4);
            float z = ReadAddr<float>(ptr + off + 8);
            if (!isSaneF(x) || !isSaneF(y) || !isSaneF(z)) continue;
            if (fabsf(x) < 0.1f && fabsf(y) < 0.1f && fabsf(z) < 0.1f) continue;
            if (fabsf(x) > 500.0f || fabsf(y) > 500.0f || fabsf(z) > 500.0f) continue;
            HLog(@"      +0x%03llx = (%.3f, %.3f, %.3f)", off, x, y, z);
            break;
        }
    }
}

static void DumpWorker(void) {
    std::this_thread::sleep_for(std::chrono::milliseconds(3000));
    int index = 0;

    while (index < 2) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        if (!aimMagnet) continue;

        if (Moudule_Base == (uint64_t)-1)
            Moudule_Base = (uint64_t)GetGameModule_Base((char *)"FreeFire");
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

        uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
        if (!isVaildPtr(entriesArr)) continue;

        int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
        if (slotCap <= 0 || slotCap > 256) continue;

        const uint64_t base = entriesArr + kIl2CppArrayItems;

        for (int i = 0; i < slotCap && index < 2; i++) {
            uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
            if (ReadAddr<int>(ent) == 0) continue;

            uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
            if (!isVaildPtr(pawn)) continue;
            if (isLocalTeamMate(myPawn, pawn)) continue;
            if (get_CurHP(pawn) <= 0) continue;

            index++;
            DumpPawn(pawn, index);
        }
    }
}

void HeadDumpStart(void) {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(DumpWorker).detach();
}

@interface _HeadDumpBootstrap : NSObject @end
@implementation _HeadDumpBootstrap
+ (void)load { HeadDumpStart(); }
@end
