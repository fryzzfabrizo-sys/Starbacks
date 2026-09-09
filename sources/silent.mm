#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"
#include <mutex>
#include <thread>
#include <chrono>

// ─── Extern: bestTarget ────────────────────────────────────────────
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Shared state ──────────────────────────────────────────────────
static std::mutex  silentLock;
static void       *g_HitObjInfo = nullptr;
static Vector3     g_TargetPos  = {0.0f, 0.0f, 0.0f};
static bool        g_HasData    = false;

// ─── Вспомогательная проверка валидности (аналог isVaildPtr) ─────
static inline bool isValidPtr(void *p) {
    uint64_t addr = (uint64_t)p;
    return addr >= 0x100000000ULL && addr <= 0x0000FFFFFFFFFFFFULL;
}

// ─── Helper: lấy enemy gần nhất ──────────────────────────────────
static uint64_t GetClosestEnemysilent1() {
    if (!isValidPtr((void*)g_SilentBestTarget)) return 0;
    return g_SilentBestTarget;
}

// ─── Helper: lấy vị trí đầu địch ─────────────────────────────────
static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isValidPtr((void*)pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isValidPtr((void*)headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

// ─── Background thread ─────────────────────────────────────────────
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

        // --- Добавленная проверка валидности ---
        if (!isValidPtr(currentHitObj)) {
            silentLock.lock();
            g_HasData = false;
            g_HitObjInfo = nullptr;
            silentLock.unlock();
            continue;
        }

        Vector3 ammoBase = *(Vector3 *)((uint64_t)currentHitObj + 0x4C);
        // --- Если ammoBase нулевая – структура ещё не готова ---
        if (ammoBase.x == 0.0f && ammoBase.y == 0.0f && ammoBase.z == 0.0f) continue;

        Vector3 dir;
        dir.x = targetPos.x - ammoBase.x;
        dir.y = targetPos.y - ammoBase.y;
        dir.z = targetPos.z - ammoBase.z;

        *(Vector3 *)((uint64_t)currentHitObj + 0x40) = dir;
        *(Vector3 *)((uint64_t)currentHitObj + 0x28) = targetPos;
    }
}

// ─── Gọi mỗi frame ────────────────────────────────────────────────
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

    if (!isValidPtr((void*)cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    if (!isValidPtr((void*)localPlayer)) return;

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
    if (!isValidPtr(hitObjInfo)) return;

    Vector3 enemyHeadPos = GetHeadPosition(closestEnemy);
    if (enemyHeadPos.x == 0.0f && enemyHeadPos.y == 0.0f && enemyHeadPos.z == 0.0f) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData    = false;
            g_HitObjInfo = nullptr;
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

// ─── Инициализация потока ─────────────────────────────────────────
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
    g_HasData    = false;
    g_HitObjInfo = nullptr;
    g_TargetPos  = {0.0f, 0.0f, 0.0f};
    silentLock.unlock();
}
