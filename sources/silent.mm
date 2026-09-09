#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"
#include <mutex>
#include <thread>
#include <chrono>
#include <cmath>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Shared state ──────────────────────────────────────────────────
static std::mutex  silentLock;
static uint64_t    g_HitObjInfo = 0;
static Vector3     g_TargetPos  = {0.0f, 0.0f, 0.0f};
static bool        g_HasData    = false;
static uint64_t    g_lastLocal  = 0;

// ─── Helper: получить позицию головы ─────────────────────────────
static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

// ─── Background thread: постоянная запись (без IsFiring) ──────────
static void AimSilentThread() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1)); // 1 нс
        if (!g_HasData) continue;

        silentLock.lock();
        uint64_t hitObj = g_HitObjInfo;
        Vector3  targetPos = g_TargetPos;
        bool     valid = g_HasData;
        silentLock.unlock();

        if (!valid || !isVaildPtr(hitObj)) continue;

        // Читаем ammoBase (StartPosition)
        Vector3 ammoBase = ReadAddr<Vector3>(hitObj + 0x4C);
        // Если нулевая – выходим (структура не готова)
        if (ammoBase.x == 0.0f && ammoBase.y == 0.0f && ammoBase.z == 0.0f)
            continue;

        // Вычисляем direction (ненормализованный)
        Vector3 dir;
        dir.x = targetPos.x - ammoBase.x;
        dir.y = targetPos.y - ammoBase.y;
        dir.z = targetPos.z - ammoBase.z;

        // Записываем через WriteAddr
        WriteAddr<Vector3>(hitObj + 0x40, dir);   // RayDir
        WriteAddr<Vector3>(hitObj + 0x28, targetPos); // target position
        WriteAddr<float>  (hitObj + 0x5C, 0.0f);   // scatter = 0 (убираем разброс)
    }
}

// ─── Вызывается каждый кадр из esp.mm ─────────────────────────────
void RunSilentAim() {
    if (!aimsilent1) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData = false;
            g_HitObjInfo = 0;
            silentLock.unlock();
        }
        return;
    }

    if (!isVaildPtr(cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(localPlayer)) return;

    // ─── Убрана проверка get_IsFiring ─────────────────────────────
    // Теперь сайлент работает постоянно, без привязки к выстрелу.

    // Сброс при смене матча
    if (localPlayer != g_lastLocal) {
        g_lastLocal = localPlayer;
        silentLock.lock();
        g_HasData = false;
        g_HitObjInfo = 0;
        silentLock.unlock();
        return;
    }

    uint64_t closestEnemy = g_SilentBestTarget;
    if (!isVaildPtr(closestEnemy)) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData = false;
            g_HitObjInfo = 0;
            silentLock.unlock();
        }
        return;
    }

    // Читаем HitObjectInfo из localPlayer + 0xDC8 (как в оригинале)
    uint64_t hitObjInfo = ReadAddr<uint64_t>(localPlayer + 0xDC8);
    if (!isVaildPtr(hitObjInfo)) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData = false;
            g_HitObjInfo = 0;
            silentLock.unlock();
        }
        return;
    }

    Vector3 enemyHeadPos = GetHeadPosition(closestEnemy);
    if (enemyHeadPos.x == 0.0f && enemyHeadPos.y == 0.0f && enemyHeadPos.z == 0.0f) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData = false;
            g_HitObjInfo = 0;
            silentLock.unlock();
        }
        return;
    }

    silentLock.lock();
    g_HitObjInfo = hitObjInfo;
    g_TargetPos  = enemyHeadPos;
    g_HasData    = true;
    silentLock.unlock();
}

// ─── Инициализация потока (вызывается один раз) ──────────────────
void InitSilentAimThread() {
    static bool started = false;
    if (!started) {
        started = true;
        std::thread(AimSilentThread).detach();
    }
}

// ─── Сброс состояния (для esp.mm) ────────────────────────────────
void ResetSilentAim() {
    silentLock.lock();
    g_HasData = false;
    g_HitObjInfo = 0;
    g_TargetPos = {0.0f, 0.0f, 0.0f};
    silentLock.unlock();
    g_lastLocal = 0;
}
