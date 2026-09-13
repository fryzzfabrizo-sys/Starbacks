// silent.mm
// Silent aim + диагностика путей до HeadCollider

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>
#include <chrono>
#include <cstdio>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

// диагностические пути
static constexpr uint64_t kPlayer_AimCollider = 0x6C8;
static constexpr uint64_t kPlayer_LockAimCol  = 0x140;
static constexpr uint64_t kPlayer_FollowCam   = 0x620;
static constexpr uint64_t kPlayer_Attributes  = 0x700;
static constexpr uint64_t kHit_HeadCollider   = 0x20;
static constexpr uint64_t kHit_HitLoc         = 0x28;
static constexpr uint64_t kHit_GameObject     = 0x18;

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

static std::chrono::steady_clock::time_point g_lastLog =
    std::chrono::steady_clock::now();

// ─── Helpers ────────────────────────────────────────────────────────
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};
    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};
    return getPositionExt(node);
}

static void LogLine(const char* fmt, ...) {
    FILE* f = fopen("/var/mobile/Documents/sa_diag.log", "a");
    if (!f) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fclose(f);
}

// ─── Worker ─────────────────────────────────────────────────────────
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h, target;
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h      = g_aimPtr;
            tPos   = g_tPos;
            target = g_SilentBestTarget;
        }

        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }

        // Пишем только RayDir (рабочий вариант)
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(h + kHit_RayDir, diff);

        // ── Диагностика: раз в 500 мс ──────────────────────────────
        auto now = std::chrono::steady_clock::now();
        auto ms  = std::chrono::duration_cast<std::chrono::milliseconds>(
                       now - g_lastLog).count();
        if (ms < 500) continue;
        g_lastLog = now;

        if (!validPtr(target)) continue;

        uint64_t c6C8       = ReadAddr<uint64_t>(target + kPlayer_AimCollider);
        uint64_t c140       = ReadAddr<uint64_t>(target + kPlayer_LockAimCol);
        uint64_t c6C8_10    = validPtr(c6C8) ? ReadAddr<uint64_t>(c6C8 + 0x10) : 0;
        uint64_t c6C8_18    = validPtr(c6C8) ? ReadAddr<uint64_t>(c6C8 + 0x18) : 0;
        uint64_t c140_10    = validPtr(c140) ? ReadAddr<uint64_t>(c140 + 0x10) : 0;
        uint64_t fc         = ReadAddr<uint64_t>(target + kPlayer_FollowCam);
        uint64_t attrs      = ReadAddr<uint64_t>(target + kPlayer_Attributes);
        uint64_t attrs_140  = validPtr(attrs) ? ReadAddr<uint64_t>(attrs + 0x140) : 0;

        // HitInfo текущий (эталон — сюда игра пишет сама при реальном попадании)
        uint64_t hiCol      = ReadAddr<uint64_t>(h + kHit_HeadCollider);
        uint64_t hiGO       = ReadAddr<uint64_t>(h + kHit_GameObject);
        Vector3  hiLoc      = ReadAddr<Vector3>(h + kHit_HitLoc);

        LogLine("[SA-DIAG] tgt=0x%llx  hitInfo=0x%llx", target, h);
        LogLine("  HI.Col      = 0x%llx   <-- ЭТАЛОН", hiCol);
        LogLine("  HI.GameObj  = 0x%llx", hiGO);
        LogLine("  HI.HitLoc   = (%.2f, %.2f, %.2f)", hiLoc.x, hiLoc.y, hiLoc.z);
        LogLine("  Player+6C8  = 0x%llx", c6C8);
        LogLine("  Player+140  = 0x%llx", c140);
        LogLine("  6C8+10      = 0x%llx", c6C8_10);
        LogLine("  6C8+18      = 0x%llx", c6C8_18);
        LogLine("  140+10      = 0x%llx", c140_10);
        LogLine("  Player+620  = 0x%llx", fc);
        LogLine("  Attrs+140   = 0x%llx", attrs_140);
        LogLine("  ---");
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
    g_tPos   = {};
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
        g_lastMatch = 0;
        ResetSilentAim();
        return;
    }

    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!validPtr(local) || !validPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (!validVec(tPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
    }
    g_hasData.store(true, std::memory_order_release);

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };
    WriteAddr<Vector3>(aimPtr + kHit_RayDir, diff);
}
