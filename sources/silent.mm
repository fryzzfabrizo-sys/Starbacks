// silent.mm
// Полная подмена HitInfo для обхода стен

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>
#include <unordered_map>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

static constexpr uint64_t HI_HitObject     = 0x18;
static constexpr uint64_t HI_HitCollider   = 0x20;
static constexpr uint64_t HI_HitLocation   = 0x28;
static constexpr uint64_t HI_HitNormal     = 0x34;
static constexpr uint64_t HI_RayDir        = 0x40;
static constexpr uint64_t HI_StartPosition = 0x4C;
static constexpr uint64_t HI_Damage        = 0x58;
static constexpr uint64_t HI_Distance      = 0x5C;
static constexpr uint64_t HI_ActorLayer    = 0x60;
static constexpr uint64_t HI_HitGroup      = 0x64;
static constexpr uint64_t HI_IgnoreHappens = 0x70;
static constexpr uint64_t HI_ViewBlocked   = 0x71;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

// Кэш: цель → её игровой коллайдер + gameObject
static std::mutex g_cacheLock;
static std::unordered_map<uint64_t, uint64_t> g_colliderCache;
static std::unordered_map<uint64_t, uint64_t> g_objectCache;

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

static float vlen3(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }

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
        if (!validPtr(h) || !validVec(tPos)) { std::this_thread::yield(); continue; }

        Vector3 startPos = ReadAddr<Vector3>(h + HI_StartPosition);
        Vector3 rayDir   = { tPos.x - startPos.x,
                             tPos.y - startPos.y,
                             tPos.z - startPos.z };
        float   dist     = vlen3(rayDir);

        // 1. Читаем текущий raycast
        int32_t  actorLayer = ReadAddr<int32_t> (h + HI_ActorLayer);
        uint64_t hitColl    = ReadAddr<uint64_t>(h + HI_HitCollider);
        uint64_t hitObj     = ReadAddr<uint64_t>(h + HI_HitObject);

        // 2. Кэшируем когда реально попали в игрока
        if (actorLayer == 13 && validPtr(hitColl) && validPtr(target)) {
            std::lock_guard<std::mutex> lk(g_cacheLock);
            g_colliderCache[target] = hitColl;
            if (validPtr(hitObj)) g_objectCache[target] = hitObj;
        }

        // 3. Пишем RayDir — основной канал
        WriteAddr<Vector3>(h + HI_RayDir, rayDir);

        // 4. Если стена — подменяем на полное попадание в игрока
        if (actorLayer != 13 && validPtr(target)) {
            uint64_t cachedColl = 0, cachedObj = 0;
            {
                std::lock_guard<std::mutex> lk(g_cacheLock);
                auto it  = g_colliderCache.find(target);
                if (it != g_colliderCache.end())  cachedColl = it->second;
                auto it2 = g_objectCache.find(target);
                if (it2 != g_objectCache.end())   cachedObj  = it2->second;
            }

            if (validPtr(cachedColl)) {
                // Нормализованный RayDir * dist
                float inv = (dist > 0.0001f) ? (1.0f / dist) : 0.0f;
                Vector3 rayN = { rayDir.x * inv, rayDir.y * inv, rayDir.z * inv };

                WriteAddr<uint64_t>(h + HI_HitCollider,   cachedColl);
                if (validPtr(cachedObj))
                    WriteAddr<uint64_t>(h + HI_HitObject, cachedObj);

                WriteAddr<Vector3>(h + HI_RayDir,       rayN);  // единичный
                WriteAddr<Vector3>(h + HI_HitLocation,  tPos);
                WriteAddr<Vector3>(h + HI_HitNormal,    {0.f, 1.f, 0.f});
                WriteAddr<float>  (h + HI_Distance,     dist);
                WriteAddr<int32_t>(h + HI_ActorLayer,   13);
                WriteAddr<int32_t>(h + HI_HitGroup,     1);   // 1 = head
                WriteAddr<uint8_t>(h + HI_IgnoreHappens, 0);
                WriteAddr<uint8_t>(h + HI_ViewBlocked,   0);
            }
        }
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
    std::lock_guard<std::mutex> lk2(g_cacheLock);
    g_colliderCache.clear();
    g_objectCache.clear();
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

    // быстрая запись в кадре
    Vector3 origin = ReadAddr<Vector3>(aimPtr + HI_StartPosition);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };
    WriteAddr<Vector3>(aimPtr + HI_RayDir, diff);
}
