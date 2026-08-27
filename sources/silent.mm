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

// iOS ARM64 OB54 оффсеты (из OB53 dump + сдвиг)
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // m_LastAimingInfoFromWeapon
static constexpr uint64_t kHit_RayDir         = 0x40;  // Vector3 RayDir (только это)
static constexpr uint64_t kHit_StartPos       = 0x4C;  // Vector3 StartPosition (читаем)
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr  = 0;
static Vector3           g_tPos    = {};
static Vector3           g_lPos    = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Упрощенная функция скорости (без PhysX)
static Vector3 GetTargetVelocity(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    
    static uint64_t lastPawn = 0;
    static Vector3 lastPos = {};
    static auto lastTime = std::chrono::steady_clock::now();
    
    Vector3 currentPos = HeadPos(pawn);
    auto currentTime = std::chrono::steady_clock::now();
    
    float dt = std::chrono::duration<float>(currentTime - lastTime).count();
    
    Vector3 velocity = {};
    if (lastPawn == pawn && dt > 0.001f && dt < 0.1f) {
        velocity.x = (currentPos.x - lastPos.x) / dt;
        velocity.y = (currentPos.y - lastPos.y) / dt;
        velocity.z = (currentPos.z - lastPos.z) / dt;
        
        // Ограничиваем скорость (чтобы не было выбросов)
        float maxSpeed = 20.0f;
        float speed = std::sqrt(velocity.x*velocity.x + velocity.y*velocity.y + velocity.z*velocity.z);
        if (speed > maxSpeed) {
            velocity.x *= maxSpeed / speed;
            velocity.y *= maxSpeed / speed;
            velocity.z *= maxSpeed / speed;
        }
    }
    
    lastPawn = pawn;
    lastPos = currentPos;
    lastTime = currentTime;
    
    return velocity;
}

// Предсказание позиции с учетом скорости цели
static Vector3 PredictTargetPos(Vector3 currentPos, Vector3 targetVel, Vector3 myPos, float bulletSpeed = 500.0f) {
    if (bulletSpeed <= 0) return currentPos;
    
    float distance = Vector3::Distance(myPos, currentPos);
    float flightTime = distance / bulletSpeed;
    
    // Ограничиваем время полета
    if (flightTime > 0.5f) flightTime = 0.5f;
    
    Vector3 predicted = {
        currentPos.x + targetVel.x * flightTime,
        currentPos.y + targetVel.y * flightTime,
        currentPos.z + targetVel.z * flightTime
    };
    
    return predicted;
}

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(500));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t h;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            lPos = g_lPos;
        }
        if (!isVaildPtr(h)) continue;

        // Читаем реальный StartPos из объекта
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        Vector3 diff  = { tPos.x-origin.x, tPos.y-origin.y, tPos.z-origin.z };
        float   lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };

        // Пишем RayDir
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

    // Проверяем, жив ли target
    if (get_CurHP(target) <= 0) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Гранаты и IceWall не тратят ammo
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

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Получаем скорость цели
    Vector3 targetVel = GetTargetVelocity(target);
    
    // Получаем позицию локального игрока
    Vector3 lPos = HeadPos(local);
    
    // Предсказываем позицию (компенсация упреждения)
    float bulletSpeed = 500.0f;  // Можно настроить под оружие
    Vector3 predictedPos = PredictTargetPos(tPos, targetVel, lPos, bulletSpeed);

    // Небольшое смещение вниз для точного попадания в голову
    predictedPos.y += 0.02f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = predictedPos;
        g_lPos   = lPos;
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}
