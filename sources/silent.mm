#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Вспомогательная функция для получения позиции головы ─────────
static Vector3 GetHeadPositionSafe(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

// ─── Основная функция, вызывается каждый кадр ────────────────────
void RunSilentAim() {
    @try {
        if (!aimsilent1) return;
        if (!isVaildPtr(cachedMatch)) return;

        uint64_t localPlayer = getLocalPlayer(cachedMatch);
        if (!isVaildPtr(localPlayer)) return;

        if (!get_IsFiring(localPlayer)) return;

        uint64_t closestEnemy = g_SilentBestTarget;
        if (!isVaildPtr(closestEnemy)) return;

        // Читаем HitObjectInfo как uint64_t
        uint64_t hitObjInfo = *(uint64_t *)((uint64_t)localPlayer + 0xDC8);
        if (!isVaildPtr(hitObjInfo)) return;

        // Позиция головы врага
        Vector3 targetPos = GetHeadPositionSafe(closestEnemy);
        if (targetPos.x == 0.0f && targetPos.y == 0.0f && targetPos.z == 0.0f) return;

        // Читаем ammoBase
        Vector3 ammoBase = *(Vector3 *)(hitObjInfo + 0x4C);
        if (ammoBase.x == 0.0f && ammoBase.y == 0.0f && ammoBase.z == 0.0f) return;

        // Вычисляем направление (ненормализованное)
        Vector3 dir;
        dir.x = targetPos.x - ammoBase.x;
        dir.y = targetPos.y - ammoBase.y;
        dir.z = targetPos.z - ammoBase.z;

        // Записываем
        *(Vector3 *)(hitObjInfo + 0x40) = dir;
        *(Vector3 *)(hitObjInfo + 0x28) = targetPos;
    } @catch (NSException *e) {
        // Игнорируем любые исключения – чит не падает
    }
}

void InitSilentAimThread() {
    // Ничего не делаем – синхронная запись
}

void ResetSilentAim() {
    // Ничего не делаем
}
