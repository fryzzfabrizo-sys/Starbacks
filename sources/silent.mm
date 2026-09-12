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
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_Scatter        = 0x5C;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr         = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_lastLocal  = 0;
static uint64_t          g_lastTarget = 0;
static uint64_t          g_lastMatch  = 0;

// ═══ CHAIN KILL ═══
static uint64_t          g_chainTarget = 0;
static uint64_t          g_chainCooldownUntil = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline uint64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══ Проверка: цель "небоеспособна"? ═══
// Возвращает true если цель мертва ИЛИ в нокдауне (downed).
static bool IsTargetDown(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return true;

    // Мёртв?
    if (get_CurHP(pawn) <= 0) return true;

    // Нокдаун?
    if (get_IsKnockedDown(pawn)) return true;

    return false;
}

// ═══════════════════════════════════════════════════════════════
//  Найти ближайшего живого (не downed) врага
// ═══════════════════════════════════════════════════════════════
static uint64_t FindNextTarget(uint64_t match, uint64_t local, uint64_t exclude) {
    if (!isVaildPtr(match) || !isVaildPtr(local)) return 0;

    uint64_t playerDict = ReadAddr<uint64_t>(match + kMatchPlayerDict);
    if (!isVaildPtr(playerDict)) return 0;

    uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
    if (!isVaildPtr(entriesArr)) return 0;

    int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
    if (slotCap <= 0 || slotCap > 256) return 0;

    Vector3 lPos = HeadPos(local);
    if (lPos.x == 0.0f && lPos.y == 0.0f && lPos.z == 0.0f) return 0;

    uint64_t best   = 0;
    float    bestSq = 1e18f;
    uint64_t base   = entriesArr + kIl2CppArrayItems;

    for (int i = 0; i < slotCap; i++) {
        uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
        if (ReadAddr<int>(ent) == 0) continue;

        uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
        if (!isVaildPtr(pawn)) continue;
        if (pawn == local) continue;
        if (pawn == exclude) continue;
        if (isLocalTeamMate(local, pawn)) continue;

        // Пропускаем мёртвых и нокдаун
        if (IsTargetDown(pawn)) continue;

        Vector3 ePos = HeadPos(pawn);
        if (ePos.x == 0.0f && ePos.y == 0.0f && ePos.z == 0.0f) continue;

        float dx = ePos.x - lPos.x;
        float dy = ePos.y - lPos.y;
        float dz = ePos.z - lPos.z;
        float dSq = dx*dx + dy*dy + dz*dz;
        if (dSq < bestSq) {
            bestSq = dSq;
            best   = pawn;
        }
    }
    return best;
}

// ═══════════════════════════════════════════════════════════════
//  WORKER THREAD
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            lPos = g_lPos;
            vel  = g_targetVelocity;
        }
        if (!validPtr(h)) continue;

        Vector3 predPos = {
            tPos.x + vel.x * 0.06f,
            tPos.y + vel.y * 0.06f,
            tPos.z + vel.z * 0.06f
        };

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { predPos.x - origin.x, predPos.y - origin.y, predPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
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
    g_lastLocal      = 0;
    g_lastTarget     = 0;
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    g_chainTarget    = 0;
    g_chainCooldownUntil = 0;
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

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    // ═══════════════════════════════════════════════════════════
    //  CHAIN KILL — переключение при смерти ИЛИ нокдауне
    // ═══════════════════════════════════════════════════════════
    uint64_t target = g_SilentBestTarget;
    uint64_t now = nowMs();
    bool canSwitch = (now >= g_chainCooldownUntil);

    if (isVaildPtr(g_chainTarget)) {
        // Цель мертва или в нокдауне?
        if (IsTargetDown(g_chainTarget)) {
            g_chainTarget = 0;
            if (canSwitch) {
                uint64_t next = FindNextTarget(cachedMatch, local, 0);
                if (isVaildPtr(next)) {
                    g_chainTarget = next;
                    g_chainCooldownUntil = now + 50;   // 50 мс
                    target = next;
                }
            }
        } else {
            // Цель активна — работаем по ней
            target = g_chainTarget;
        }
    }

    // Fallback — если chain не дал цель
    if (!isVaildPtr(target)) {
        target = g_SilentBestTarget;
    }
    if (!isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    // Запоминаем как chain-цель если её не было
    if (!isVaildPtr(g_chainTarget)) {
        g_chainTarget = target;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    // Скорость цели
    if (g_prevTargetPos.x != 0.0f || g_prevTargetPos.y != 0.0f || g_prevTargetPos.z != 0.0f) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float distSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        if (distSq < 25.0f) {
            g_targetVelocity = delta;
        } else {
            g_targetVelocity = {0.0f, 0.0f, 0.0f};
        }
    } else {
        g_targetVelocity = {0.0f, 0.0f, 0.0f};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_lPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенный пинг
    if (validPtr(aimPtr)) {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = g_lPos;
        Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq > 0.0001f) {
            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };
            WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
            WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);
        }
    }
}
