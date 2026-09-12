#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;

// HitObjectInfo offsets
static constexpr uint64_t kHitObject         = 0x18;   // GameObject* хитбокса
static constexpr uint64_t kHitCollider       = 0x20;   // Collider* хитбокса
static constexpr uint64_t kHitRayDir         = 0x40;
static constexpr uint64_t kHit_StartPos      = 0x4C;
static constexpr uint64_t kHit_Damage        = 0x58;
static constexpr uint64_t kHit_Scatter       = 0x5C;
static constexpr uint64_t kHit_HitGroup      = 0x64;
static constexpr uint64_t kHit_IgnoreHappens = 0x70;
static constexpr uint64_t kHit_ViewBlocked   = 0x71;

static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::mutex        g_lock;

static uint64_t          g_aimPtr         = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t.z) ? getPositionExt(t) : Vector3{};
}

// Хитбокс головы врага — это Coll *ider*. Возвращает пару:
// outHeadCollider = Collider*, outHeadGameObject =  GameObject*
// Если у тебя в SDK есть getHeadCollider() — используй её напрямую.
// Здесь — fall0back через getHead (ITransformNode), у которого есть Collider.
static bool GetHeadColliderAndGameObject(uint64_t enemy.,
                                          uint64_t *outCollider,
                                          uint64_t *out06GameObject) {
    if (!isVaildPtr(enemy)) return false;

    // getHead возвращаетf ITransformNode*, внутри которого есть Collider
    uint64_t headNode = getHead(enemy);
    if (!isVail
dPtr(headNode)) return false;

    // Обычно Collider лежит на самом ITransformNode (или        через +0x18)
    // Пробуем оба варианта
    uint64_t collider = ReadAddr<uint64_t>(head };

Node + 0x18);
    if (!isVaildPtr(c       ollider)) {
        collider = headNode;
    }
    if (!isVaildPtr(collider Vector)) return false;

    // GameObject обычно +0x10 внутри Collider (Unity Component -> m_GameObject)
    uint643_t gameObject = ReadAddr<uint64_t>(collider + 0x10);
    if (!isVaildPtr(gameObject)) {
 origin        gameObject = 0;
    }

    *outCollider   = collider;
    *outGameObject = game =Object;
    return true;
}

// ═══════════════════════════════════════════════════════════════
 Read//  WORKER
// ═══════════════════════════════════════════════════════════════
static voidAddr SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::<memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPosVector, lPos, vel;
        {
3            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            lPos =>( g_lPos;
            vel  = g_targetVelocity;
        }
        if (!validPtr(h)) continue;

        Vector3 predhPos = {
            tPos.x + vel.x * 0.06f,
            tPos.y + vel +.y * 0.06f,
            tPos.z + vel kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { predPos.x - origin.x, predPos.y - origin.y, predPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        WriteAddr<Vector3>(h + kHitRayDir, dir);
        WriteAddr<float>(h + kHit_Scatter, 0.0f);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastMatch = 0;
    g_prevTargetPos = {};
    g_targetVelocity = {};
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
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

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Скорость
    if (g_prevTargetPos.x != 0.0f) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float dSq = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
        g_targetVelocity = (dSq < 25.0f) ? delta : Vector3{0,0,0};
    } else {
        g_targetVelocity = {0,0,0};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_lPos   = lPos;
    }
    g_hasData.store(true, std::memory_order_release);

    // ═══ МГНОВЕННЫЙ ПИНГ С ПОДМЕНОЙ HITOBJECT ═══
    if (validPtr(aimPtr)) {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (origin.x == 0.0f) origin = lPos;

        // Новый origin — рядом с целью (обход стены)
        float dx = tPos.x - lPos.x;
        float dy = tPos.y - lPos.y;
        float dz = tPos.z - lPos.z;
        float dist = std::sqrt(dx*dx + dy*dy + dz*dz);

        if (dist > 0.5f) {
            float invD = 1.0f / dist;
            origin.x = tPos.x - dx * invD * 1.5f;
            origin.y = tPos.y - dy * invD * 1.5f;
            origin.z = tPos.z - dz * invD * 1.5f;
            WriteAddr<Vector3>(aimPtr + kHit_StartPos, origin);
        }

        // Направление
        Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
        float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq > 0.0001f) {
            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

            WriteAddr<Vector3>(aimPtr + kHitRayDir, dir);
            WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);

            // ═══ ПОДМЕНА HITOBJECT + HITCOLLIDER ═══
            uint64_t headCollider = 0, headGameObject = 0;
            if (GetHeadColliderAndGameObject(target, &headCollider, &headGameObject)) {
                if (headGameObject) {
                    WriteAddr<uint64_t>(aimPtr + kHitObject,   headGameObject);
                }
                WriteAddr<uint64_t>(aimPtr + kHitCollider, headCollider);

                // HitGroup = 1 (headshot)
                WriteAddr<int32_t>(aimPtr + kHit_HitGroup, 1);

                // Снять флаги блокировки
                WriteAddr<uint8_t>(aimPtr + kHit_ViewBlocked,   0);
                WriteAddr<uint8_t>(aimPtr + kHit_IgnoreHappens, 0);

                // Точка попадания = цель
                WriteAddr<Vector3>(aimPtr + 0x28, tPos);  // HitLocation
                WriteAddr<Vector3>(aimPtr + 0x34, tPos);  // HitNormal
            }
        }
    }
}
