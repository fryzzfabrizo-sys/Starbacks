// SilentAim.mm
// Silent aim строго через ITransformNode головы (0x638)
// + заполнение HitInfo всеми полями из dump54

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Player field offsets ───────────────────────────────────────────
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;   // Player_HitObjectInfoWp
static constexpr uint64_t kPlayer_HeadNode    = 0x638;   // Player_HeadTF
static constexpr uint64_t kPlayer_RootTF      = 0x660;   // Player_RootTF
static constexpr uint64_t kBodyPart_TransNode = 0x10;

// ─── HitInfo (GMPGMPFNMFP) field offsets ────────────────────────────
static constexpr uint64_t kHit_GameObject     = 0x18;    // ← не трогаем (ptr)
static constexpr uint64_t kHit_HeadCollider   = 0x20;    // ← не трогаем (ptr)
static constexpr uint64_t kHit_HitLoc         = 0x28;    // Vector3 target pos
static constexpr uint64_t kHit_Normal         = 0x34;    // Vector3 normal
static constexpr uint64_t kHit_RayDir         = 0x40;    // Vector3 ray dir
static constexpr uint64_t kHit_StartPos       = 0x4C;    // Vector3 start
static constexpr uint64_t kHit_OrgStrtPos     = 0x74;    // Vector3 original start
static constexpr uint64_t kHit_Part           = 0x64;    // int 0=Default 1=Head 2=Body
static constexpr uint64_t kHit_Ignore         = 0x70;    // bool
static constexpr uint64_t kHit_SpecialHitType = 0x80;    // int
static constexpr uint64_t kHitInfo_Damage     = 0x58;    // int
static constexpr uint64_t kHitInfo_Distance   = 0x5C;    // float

// ─── State ──────────────────────────────────────────────────────────
static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

// ─── Helpers ────────────────────────────────────────────────────────
static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}

// Player + 0x638 -> BodyPart + 0x10 -> Transform -> getPositionExt
static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};

    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};

    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};

    return getPositionExt(node);
}

// Заполнить HitInfo всеми полями
static void FillHitInfo(uint64_t hitInfo,
                        const Vector3& origin,
                        const Vector3& targetPos,
                        const Vector3& rayDir,
                        float dist)
{
    // нормализуем направление для Hit_Normal
    float len = std::sqrt(rayDir.x*rayDir.x + rayDir.y*rayDir.y + rayDir.z*rayDir.z);
    Vector3 normDir = {0.f, 0.f, 0.f};
    if (len > 0.0001f) {
        normDir.x = rayDir.x / len;
        normDir.y = rayDir.y / len;
        normDir.z = rayDir.z / len;
    }

    WriteAddr<Vector3>(hitInfo + kHit_HitLoc,     targetPos);
    WriteAddr<Vector3>(hitInfo + kHit_Normal,     normDir);
    WriteAddr<Vector3>(hitInfo + kHit_RayDir,     rayDir);
    WriteAddr<Vector3>(hitInfo + kHit_OrgStrtPos, origin);

    WriteAddr<int>(hitInfo  + kHit_Part,           1);       // 1 = Head
    WriteAddr<int>(hitInfo  + kHit_SpecialHitType, 1);       // special = head
    WriteAddr<bool>(hitInfo + kHit_Ignore,         false);   // не игнорировать
    WriteAddr<float>(hitInfo + kHitInfo_Distance,  dist);

    // ⚠️ Damage НЕ трогаем — если писать, легко ловится.
    // Если очень надо — раскомментируй и подбери значение:
    // WriteAddr<int>(hitInfo + kHitInfo_Damage, 60);
}

// ─── Silent Worker ──────────────────────────────────────────────────
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

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };

        float dist = std::sqrt(diff.x*diff.x + diff.y*diff.y + diff.z*diff.z);
        if (dist < 0.01f) continue;

        FillHitInfo(h, origin, tPos, diff, dist);
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

// ─── Main ───────────────────────────────────────────────────────────
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

    // мгновенная запись в кадре
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };

    float dist = std::sqrt(diff.x*diff.x + diff.y*diff.y + diff.z*diff.z);
    if (dist < 0.01f) return;

    FillHitInfo(aimPtr, origin, tPos, diff, dist);
}
