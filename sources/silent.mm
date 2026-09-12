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
static constexpr uint64_t kHit_Scatter        = 0x5C; // Офсет разброса в хит-инфо

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr         = 0;
static uint64_t          g_localPlayerPtr = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_lastLocal  = 0;
static uint64_t          g_lastTarget = 0;
static uint64_t          g_lastMatch  = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Чисто экстернальный метод подавления разброса через обход указателей оружия в памяти
static void ApplyExternalNoSpread(uint64_t local_player, uint64_t h) {
    if (!validPtr(local_player)) return;

    // 1. Гасим разброс в самом хит-инфо объекте и возможных альтернативных указателях
    if (validPtr(h)) {
        WriteAddr<float>(h + kHit_Scatter, 0.0f);
    }
    
    const uint64_t hitObjOffs[3] = { 0xDD0, 0xA90, 0xAA0 };
    for (int i = 0; i < 3; i++) {
        uint64_t altHit = ReadAddr<uint64_t>(local_player + hitObjOffs[i]);
        if (validPtr(altHit)) {
            WriteAddr<float>(altHit + kHit_Scatter, 0.0f);
        }
    }

    // 2. Добираемся до текущего оружия через цепочку памяти (без вызова игровых функций)
    // Офсеты менеджера оружия и компонента огня (проверьте под вашу версию игры, если потребуется)
    uint64_t weaponManager = ReadAddr<uint64_t>(local_player + 0x2A0);
    if (validPtr(weaponManager)) {
        uint64_t weapon = ReadAddr<uint64_t>(weaponManager + 0x28);
        if (validPtr(weapon)) {
            // Обнуляем параметры разброса в самом оружии
            WriteAddr<float>(weapon + 0x4FC, 0.0f);
            WriteAddr<float>(weapon + 0x500, 0.0f);
            WriteAddr<float>(weapon + 0x510, 0.0f);

            // Контроллер стрельбы (fireCtrl)
            uint64_t fireCtrl = ReadAddr<uint64_t>(weapon + 0x80);
            if (validPtr(fireCtrl)) {
                WriteAddr<float>(fireCtrl + 0x18, 0.0f);
                WriteAddr<float>(fireCtrl + 0x1C, 0.0f);
                WriteAddr<float>(fireCtrl + 0x30, 0.0f);
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  WORKER THREAD — шпарит на максимальной скорости в обход функций
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h, localP;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h      = g_aimPtr;
            localP = g_localPlayerPtr;
            tPos   = g_tPos;
            lPos   = g_lPos;
            vel    = g_targetVelocity;
        }
        if (!validPtr(h)) continue;

        // Предсказание движения цели
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

        // Пишем жесткое направление в голову и гасим разброс через память
        WriteAddr<Vector3>(h + kHit_RayDir, dir);
        ApplyExternalNoSpread(localP, h);
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
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr         = 0;
    g_localPlayerPtr = 0;
}

// ═══════════════════════════════════════════════════════════════
//  Вызывается из updateFrame (60 fps)
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
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
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

    // Расчет скорости цели
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
        g_aimPtr         = aimPtr;
        g_localPlayerPtr = local;
        g_tPos           = tPos;
        g_lPos           = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенный первичный проход на текущем кадре
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
            ApplyExternalNoSpread(local, aimPtr);
        }
    }
}
