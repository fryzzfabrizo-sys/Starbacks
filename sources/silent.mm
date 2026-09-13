// silent.mm
// Дамп CapsuleCollider цели

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>
#include <cstdio>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_HitCollider    = 0x20;
static constexpr uint64_t kHit_ActorLayer     = 0x60;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;
static uint64_t          g_lastDumpCollider = 0;

static void LogToFile(const char* fmt, ...) {
    FILE* f = fopen("/var/mobile/Documents/collider_dump.log", "a");
    if (!f) return;
    va_list args; va_start(args, fmt);
    vfprintf(f, fmt, args); va_end(args);
    fputc('\n', f); fclose(f);
}

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

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
        }
        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }

        // Пишем RayDir как всегда
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(h + kHit_RayDir, diff);

        // ─── Дамп коллайдера ─────────────────────────────────
        uint64_t col = ReadAddr<uint64_t>(h + kHit_HitCollider);
        int32_t  lay = ReadAddr<int32_t>(h + kHit_ActorLayer);

        if (validPtr(col) && col != g_lastDumpCollider) {
            g_lastDumpCollider = col;

            LogToFile("========= COLLIDER DUMP =========");
            LogToFile("HitCollider = 0x%llx  ActorLayer=%d",
                      (unsigned long long)col, lay);

            // Дамп 64 байта от начала коллайдера
            for (int row = 0; row < 4; row++) {
                char hex[128] = {0};
                int pos = 0;
                for (int j = 0; j < 4; j++) {
                    uint32_t val = ReadAddr<uint32_t>(col + row*16 + j*4);
                    pos += snprintf(hex + pos, sizeof(hex) - pos,
                                    "%08x ", val);
                }
                LogToFile("+%02x: %s", row * 16, hex);
            }
            LogToFile("");
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(50));
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
