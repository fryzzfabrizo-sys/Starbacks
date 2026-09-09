#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// iOS ARM64 OB54 оффсеты
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // m_LastAimingInfoFromWeapon
static constexpr uint64_t kHit_RayDir         = 0x40;  // Vector3 RayDir
static constexpr uint64_t kHit_StartPos       = 0x4C;  // Vector3 StartPosition
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr  = 0;
static Vector3           g_tPos    = {};
static Vector3           g_lPos    = {};
// Переменные для расчета упреждения (velocity)
static Vector3           g_lastTargetPos = {};
static Vector3           g_targetVelocity = {};
static auto              g_lastTime = std::chrono::high_resolution_clock::now();

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos, lPos, velocity;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            tPos     = g_tPos;
            lPos     = g_lPos;
            velocity = g_targetVelocity;
        }
        if (!isVaildPtr(h)) {
            g_hasData.store(false, std::memory_order_release);
            continue;
        }

        // Предикшен: добавляем к позиции предсказанное смещение с учетом скорости цели
        // Коэффициент 0.08f регулирует силу упреждения (можно подстроить под пинг/оружие)
        Vector3 predictedPos = {
            tPos.x + velocity.x * 0.08f,
            tPos.y + velocity.y * 0.08f,
            tPos.z + velocity.z * 0.08f
        };

        // Читаем реальный StartPos из объекта
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { predictedPos.x - origin.x, predictedPos.y - origin.y, predictedPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        // Пишем вектор направления луча
        WriteAddr<Vector3>(h + kHit_RayDir, dir);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Проверка на оружие/гранаты/айсволлы
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isVaildPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 currentHead = HeadPos(target);
    if (currentHead.x == 0.0f && currentHead.y == 0.0f && currentHead.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Расчет времени и скорости цели для упреждения в движении
    auto now = std::chrono::high_resolution_clock::now();
    float deltaTime = std::chrono::duration<float>(now - g_lastTime).count();
    if (deltaTime > 0.001f && deltaTime < 0.1f) {
        if (g_lastTargetPos.x != 0.0f || g_lastTargetPos.y != 0.0f || g_lastTargetPos.z != 0.0f) {
            g_targetVelocity = {
                (currentHead.x - g_lastTargetPos.x) / deltaTime,
                (currentHead.y - g_lastTargetPos.y) / deltaTime,
                (currentHead.z - g_lastTargetPos.z) / deltaTime
            };
        }
    }
    g_lastTargetPos = currentHead;
    g_lastTime = now;

    // Смещение в центр головы
    currentHead.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = currentHead;
        g_lPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
    g_lastTargetPos = {};
    g_targetVelocity = {};
}
