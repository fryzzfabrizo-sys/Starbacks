#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"
#include <mutex>
#include <thread>
#include <chrono>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static std::mutex  silentLock;
static uint64_t    g_HitObjInfo = 0;
static Vector3     g_TargetPos  = {0.0f, 0.0f, 0.0f};
static bool        g_HasData    = false;

// Детект смены матча
static uint64_t    g_lastLocal  = 0;

static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

static void AimSilentThread() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1));
        if (!g_HasData) continue;

        silentLock.lock();
        uint64_t h       = g_HitObjInfo;
        Vector3  tPos    = g_TargetPos;
        bool     valid   = g_HasData;
        silentLock.unlock();

        if (!valid || !isVaildPtr(h)) continue;

        // offset +0x4C: StartPosition (откуда летит пуля)
        Vector3 ammoBase = ReadAddr<Vector3>(h + 0x4C);

        Vector3 dir;
        dir.x = tPos.x - ammoBase.x;
        dir.y = tPos.y - ammoBase.y;
        dir.z = tPos.z - ammoBase.z;

        float len = dir.x*dir.x + dir.y*dir.y + dir.z*dir.z;
        if (len <= 0.0001f) continue;
        float inv = 1.0f / __builtin_sqrtf(len);
        dir.x *= inv; dir.y *= inv; dir.z *= inv;

        // +0x40: RayDir — куда летит пуля
        WriteAddr<Vector3>(h + 0x40, dir);
        // +0x28: HitLocation — позиция попадания (как в оригинале)
        WriteAddr<Vector3>(h + 0x28, tPos);
        // +0x5C: scatter float — зануляем, иначе игра добавит разброс поверх нашего RayDir
        // (из Hooks.h: float PGCPFOAJHBM — без этого часть пуль уходит мимо)
        WriteAddr<float>(h + 0x5C, 0.0f);
    }
}

void InitSilentAimThread() {
    static bool started = false;
    if (!started) {
        started = true;
        std::thread(AimSilentThread).detach();
    }
}

void RunSilentAim() {
    if (!aimsilent1) {
        silentLock.lock();
        g_HasData    = false;
        g_HitObjInfo = 0;
        silentLock.unlock();
        return;
    }

    if (!isVaildPtr(cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(localPlayer)) return;

    // Фикс второго матча: при смене localPlayer сбрасываем
    if (localPlayer != g_lastLocal) {
        g_lastLocal = localPlayer;
        silentLock.lock();
        g_HasData    = false;
        g_HitObjInfo = 0;
        silentLock.unlock();
        return; // следующий кадр возьмёт свежий aimPtr
    }

    uint64_t closestEnemy = isVaildPtr(g_SilentBestTarget) ? g_SilentBestTarget : 0;
    if (!closestEnemy) {
        silentLock.lock();
        g_HasData    = false;
        g_HitObjInfo = 0;
        silentLock.unlock();
        return;
    }

    // Читаем HitObjectInfo через ReadAddr (не прямое разыменование — краш в external)
    uint64_t hitObjInfo = ReadAddr<uint64_t>(localPlayer + 0xDC8);
    if (!isVaildPtr(hitObjInfo)) return;

    Vector3 enemyHeadPos = GetHeadPosition(closestEnemy);
    if (enemyHeadPos.x == 0.0f && enemyHeadPos.y == 0.0f && enemyHeadPos.z == 0.0f) return;

    silentLock.lock();
    g_HitObjInfo = hitObjInfo;
    g_TargetPos  = enemyHeadPos;
    g_HasData    = true;
    silentLock.unlock();
}

void ResetSilentAim() {
    silentLock.lock();
    g_HasData    = false;
    g_HitObjInfo = 0;
    silentLock.unlock();
    g_lastLocal = 0;
}
