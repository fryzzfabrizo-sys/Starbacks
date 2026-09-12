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
static constexpr uint64_t kHit_Scatter        = 0x5C; // Смещение разброса пули

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr         = 0;
static uint64_t          g_localPlayerPtr = 0; // Сохраняем для доступа к оружию в потоке
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

// Вспомогательная функция для безопасного обнуления разброса в структуре оружия
static inline void tryZeroScatter(uint64_t obj, uint64_t off) {
    if (!validPtr(obj)) return;
    float v = ReadAddr<float>(obj + off);
    if (v > 0.0001f && v < 1.0f) {
        WriteAddr<float>(obj + off, 0.0f);
    }
}

// Подавление разброса оружия и текущего выстрела
static void ApplyNoSpreadOrRecoil(uint64_t local_player, uint64_t h) {
    if (!validPtr(local_player)) return;

    // 1. Обнуляем разброс в самом объекте хит-инфо (несколько возможных офсетов для надежности)
    const uint64_t hitObjOffs[4] = { 0xDC8, 0xDD0, 0xA90, 0xAA0 };
    for (int k = 0; k < 4; k++) {
        uint64_t hitObj = ReadAddr<uint64_t>(local_player + hitObjOffs[k]);
        if (validPtr(hitObj)) {
            WriteAddr<float>(hitObj + kHit_Scatter, 0.0f);
        }
    }
    if (validPtr(h)) {
        WriteAddr<float>(h + kHit_Scatter, 0.0f);
    }

    // 2. Достаем текущее оружие в руках и обнуляем разброс в fireCtrl (офсеты оружия)
    // Функция получения оружия на руках (индекс может отличаться, но логика стандартная)
    typedef uint64_t(*GetWeaponFn)(uint64_t);
    static GetWeaponFn _GetWeaponOnHand1 = (GetWeaponFn)getRealOffset(0x53BE110);
    
    if (_GetWeaponOnHand1) {
        uint64_t weapon = _GetWeaponOnHand1(local_player);
        if (validPtr(weapon)) {
            uint64_t fireCtrl = ReadAddr<uint64_t>(weapon + 0x80);
            if (validPtr(fireCtrl)) {
                tryZeroScatter(fireCtrl, 0x18);
                tryZeroScatter(fireCtrl, 0x1C);
                tryZeroScatter(fireCtrl, 0x30);
            }
            tryZeroScatter(weapon, 0x4FC);
            tryZeroScatter(weapon, 0x500);
            tryZeroScatter(weapon, 0x510);
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  WORKER THREAD — пишет направление и давит разброс на максимальной скорости
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

        // Лёгкое предсказание движения цели
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

        // Жестко переписываем направление на голову и гасим разброс
        WriteAddr<Vector3>(h + kHit_RayDir, dir);
        ApplyNoSpreadOrRecoil(localP, h);

        // Дополнительно проходим по альтернативным указателям хит-инфо в фоновом потоке
        if (validPtr(localP)) {
            const uint64_t extraOffs[3] = { 0xDD0, 0xA90, 0xAA0 };
            for (int i = 0; i < 3; i++) {
                uint64_t altHit = ReadAddr<uint64_t>(localP + extraOffs[i]);
                if (validPtr(altHit)) {
                    WriteAddr<Vector3>(altHit + kHit_RayDir, dir);
                    WriteAddr<float>(altHit + kHit_Scatter, 0.0f);
                }
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
    g_lastLocal      = 0;
    g_lastTarget     = 0;
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr         = 0;
    g_localPlayerPtr = 0;
}

// ═══════════════════════════════════════════════════════════════
//  Вызывается из updateFrame (60 fps). Обновляет данные для потока.
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

    // Оценка скорости цели
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

    // Принудительный мгновенный вызов для кадра
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
            ApplyNoSpreadOrRecoil(local, aimPtr);
        }
    }
}
