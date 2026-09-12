#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"
#include <mutex>
#include <thread>
#include <chrono>
#include <cmath>

// ─── Extern ───────────────────────────────────────────────────────
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Shared state между main thread và background thread ───────────
static std::mutex  silentLock;
static void       *g_HitObjInfo = nullptr;
static Vector3     g_TargetPos  = {0.0f, 0.0f, 0.0f};
static bool        g_HasData    = false;

// ─── Переменные для расчета упреждения (Prediction) ────────────────
static Vector3     g_LastEnemyPos = {0.0f, 0.0f, 0.0f};
static auto        g_LastTime     = std::chrono::high_resolution_clock::now();

// ─── Helper: lấy enemy gần nhất từ g_SilentBestTarget ─────────────
static uint64_t GetClosestEnemysilent1() {
    if (!isVaildPtr(g_SilentBestTarget)) return 0;
    return g_SilentBestTarget;
}

// ─── Helper: lấy vị trí đầu địch ─────────────────────────────────
static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

// ─── Background thread: redirect trajectory с нормализацией и упреждением ──
static void AimSilentThread() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_HasData) continue;

        silentLock.lock();
        void   *currentHitObj = g_HitObjInfo;
        Vector3 targetPos     = g_TargetPos;
        bool    valid         = g_HasData;
        silentLock.unlock();

        if (!valid || !currentHitObj) continue;

        // Динамическое чтение позиции выстрела в реальном времени (важно при движении локального игрока)
        Vector3 ammoBase = *(Vector3 *)((uint64_t)currentHitObj + 0x4C);

        // Расчет вектора направления: target − origin
        Vector3 dir;
        dir.x = targetPos.x - ammoBase.x;
        dir.y = targetPos.y - ammoBase.y;
        dir.z = targetPos.z - ammoBase.z;

        // Нормализация вектора (длина = 1), чтобы хитскан игры работал корректно
        float length = std::sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
        if (length > 0.0001f) {
            dir.x /= length;
            dir.y /= length;
            dir.z /= length;
        }

        // Запись нормализованного направления и предсказанной позиции в HitObjectInfo
        *(Vector3 *)((uint64_t)currentHitObj + 0x40) = dir;
        *(Vector3 *)((uint64_t)currentHitObj + 0x28) = targetPos;
    }
}

// ─── Gọi mỗi frame từ renderESPWithBuffers ────────────────────────
void RunSilentAim() {
    if (!aimsilent1) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData    = false;
            g_HitObjInfo = nullptr;
            silentLock.unlock();
        }
        return;
    }

    if (!isVaildPtr(cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(localPlayer)) return;

    if (!get_IsFiring(localPlayer)) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData    = false;
            g_HitObjInfo = nullptr;
            silentLock.unlock();
        }
        return;
    }

    uint64_t closestEnemy = GetClosestEnemysilent1();
    if (!closestEnemy) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData    = false;
            g_HitObjInfo = nullptr;
            silentLock.unlock();
        }
        return;
    }

    void *hitObjInfo = *(void **)((uint64_t)localPlayer + 0xDC8);
    if (!hitObjInfo) return;

    Vector3 currentHeadPos = GetHeadPosition(closestEnemy);

    // ─── Расчет скорости цели и предсказание позиции (Prediction) ───
    auto now = std::chrono::high_resolution_clock::now();
    float dt = std::chrono::duration<float>(now - g_LastTime).count();

    Vector3 velocity = {0.0f, 0.0f, 0.0f};
    if (dt > 0.0001f && dt < 0.1f) {
        velocity.x = (currentHeadPos.x - g_LastEnemyPos.x) / dt;
        velocity.y = (currentHeadPos.y - g_LastEnemyPos.y) / dt;
        velocity.z = (currentHeadPos.z - g_LastEnemyPos.z) / dt;
    }

    g_LastEnemyPos = currentHeadPos;
    g_LastTime     = now;

    // Время упреждения под скорость пуль (регулируйте под оружие: 0.1f — 0.2f)
    float predictionTime = 0.12f;

    Vector3 predictedPos = {
        currentHeadPos.x + velocity.x * predictionTime,
        currentHeadPos.y + velocity.y * predictionTime,
        currentHeadPos.z + velocity.z * predictionTime
    };

    silentLock.lock();
    g_HitObjInfo = hitObjInfo;
    g_TargetPos  = predictedPos;
    g_HasData    = true;
    silentLock.unlock();
}

// ─── Gọi 1 lần khi HUD khởi động ─────────────────────────────────
void InitSilentAimThread() {
    std::thread(AimSilentThread).detach();
}
