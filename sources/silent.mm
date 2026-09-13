// silent.mm
// Silent aim + дамп структуры HitInfo в файл

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

// ─── Offsets Player ─────────────────────────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

// ─── Offsets HitInfo (GMPGMPFNMFP) — читаем ВСЕ поля ────────────────
static constexpr uint64_t HI_klass           = 0x00;
static constexpr uint64_t HI_monitor         = 0x08;
static constexpr uint64_t HI_m_IsInPool      = 0x10;
static constexpr uint64_t HI_HitObject       = 0x18;
static constexpr uint64_t HI_HitCollider     = 0x20;
static constexpr uint64_t HI_HitLocation     = 0x28;
static constexpr uint64_t HI_HitNormal       = 0x34;
static constexpr uint64_t HI_RayDir          = 0x40;
static constexpr uint64_t HI_StartPosition   = 0x4C;
static constexpr uint64_t HI_Damage          = 0x58;
static constexpr uint64_t HI_Distance        = 0x5C;
static constexpr uint64_t HI_ActorLayer      = 0x60;
static constexpr uint64_t HI_HitGroup        = 0x64;
static constexpr uint64_t HI_HitPhysicMat    = 0x68;
static constexpr uint64_t HI_IgnoreHappens   = 0x70;
static constexpr uint64_t HI_ViewBlocked     = 0x71;
static constexpr uint64_t HI_OrigStartPos    = 0x74;
static constexpr uint64_t HI_SpecialHitType  = 0x80;
static constexpr uint64_t HI_SpecialHitObjID = 0x84;

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

static uint64_t g_lastLoggedCollider = 0;
static int      g_lastLoggedDamage   = -1;

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
    FILE* f = fopen("/var/mobile/Documents/hitinfo_dump.log", "a");
    if (!f) return;
    va_list args; va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fclose(f);
}

// ─── Dump HitInfo ───────────────────────────────────────────────────
static void DumpHitInfo(uint64_t h, uint64_t target, const Vector3& tPos) {
    if (!validPtr(h)) return;

    uint64_t klass        = ReadAddr<uint64_t>(h + HI_klass);
    uint64_t monitor      = ReadAddr<uint64_t>(h + HI_monitor);
    uint8_t  isInPool     = ReadAddr<uint8_t> (h + HI_m_IsInPool);
    uint64_t hitObject    = ReadAddr<uint64_t>(h + HI_HitObject);
    uint64_t hitCollider  = ReadAddr<uint64_t>(h + HI_HitCollider);
    Vector3  hitLocation  = ReadAddr<Vector3>(h + HI_HitLocation);
    Vector3  hitNormal    = ReadAddr<Vector3>(h + HI_HitNormal);
    Vector3  rayDir       = ReadAddr<Vector3>(h + HI_RayDir);
    Vector3  startPos     = ReadAddr<Vector3>(h + HI_StartPosition);
    int32_t  damage       = ReadAddr<int32_t> (h + HI_Damage);
    float    distance     = ReadAddr<float>   (h + HI_Distance);
    int32_t  actorLayer   = ReadAddr<int32_t> (h + HI_ActorLayer);
    int32_t  hitGroup     = ReadAddr<int32_t> (h + HI_HitGroup);
    uint64_t hitPhysMat   = ReadAddr<uint64_t>(h + HI_HitPhysicMat);
    uint8_t  ignoreHap    = ReadAddr<uint8_t> (h + HI_IgnoreHappens);
    uint8_t  viewBlocked  = ReadAddr<uint8_t> (h + HI_ViewBlocked);
    Vector3  origStartPos = ReadAddr<Vector3>(h + HI_OrigStartPos);
    uint8_t  specHitType  = ReadAddr<uint8_t> (h + HI_SpecialHitType);
    uint32_t specHitObjID = ReadAddr<uint32_t>(h + HI_SpecialHitObjID);

    // Логируем только когда есть активность (damage > 0 или сменился collider)
    if (damage <= 0 && hitCollider == g_lastLoggedCollider) return;
    g_lastLoggedCollider = hitCollider;
    g_lastDamage = damage;

    LogLine("========== HITINFO DUMP ==========");
    LogLine("target        = 0x%llx   head=(%.2f, %.2f, %.2f)",
            target, tPos.x, tPos.y, tPos.z);
    LogLine("hitInfo       = 0x%llx", h);
    LogLine("klass         = 0x%llx", klass);
    LogLine("monitor       = 0x%llx", monitor);
    LogLine("m_IsInPool    = %d", isInPool);
    LogLine("HitObject     = 0x%llx  <-- GameObject", hitObject);
    LogLine("HitCollider   = 0x%llx  <-- Collider", hitCollider);
    LogLine("HitLocation   = (%.2f, %.2f, %.2f)", hitLocation.x, hitLocation.y, hitLocation.z);
    LogLine("HitNormal     = (%.2f, %.2f, %.2f)", hitNormal.x, hitNormal.y, hitNormal.z);
    LogLine("RayDir        = (%.2f, %.2f, %.2f)", rayDir.x, rayDir.y, rayDir.z);
    LogLine("StartPosition = (%.2f, %.2f, %.2f)", startPos.x, startPos.y, startPos.z);
    LogLine("Damage        = %d", damage);
    LogLine("Distance      = %.2f", distance);
    LogLine("ActorLayer    = %d", actorLayer);
    LogLine("HitGroup      = %d", hitGroup);
    LogLine("HitPhysicMat  = 0x%llx", hitPhysMat);
    LogLine("IgnoreHappens = %d", ignoreHap);
    LogLine("ViewBlocked   = %d", viewBlocked);
    LogLine("OrigStartPos  = (%.2f, %.2f, %.2f)", origStartPos.x, origStartPos.y, origStartPos.z);
    LogLine("SpecialHitType= %d", specHitType);
    LogLine("SpecialHitObID= %d", specHitObjID);
    LogLine("==================================");
    LogLine("");
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

        // Пишем RayDir (как раньше)
        Vector3 origin = ReadAddr<Vector3>(h + HI_StartPosition);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        WriteAddr<Vector3>(h + HI_RayDir, diff);

        // Дамп
        DumpHitInfo(h, target, tPos);

        std::this_thread::sleep_for(std::chrono::milliseconds(30));
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

    Vector3 origin = ReadAddr<Vector3>(aimPtr + HI_StartPosition);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };
    WriteAddr<Vector3>(aimPtr + HI_RayDir, diff);
}
