#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool aimsilent1;

// Все 4 слота hitObject на Player — GMPGMPFNMFP*
// player + offset → ptr → GMPGMPFNMFP object
static constexpr uint64_t kHitObjSlots[] = { 0xA90, 0xAA0, 0xDC8, 0xDD0};

// GMPGMPFNMFP field offsets (из dump.cs)
static constexpr uint64_t kHitObj_Origin    = 0x4C; // Vector3 LMAEGPEAECO — muzzle/origin
static constexpr uint64_t kHitObj_HitPos    = 0x28; // Vector3 MBGBCLNJOMK — hit position
static constexpr uint64_t kHitObj_Direction = 0x40; // Vector3 IKDEGKIICJP — travel direction

static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

static inline bool IsZeroVec3(const Vector3& v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

// Пишем напрямую — без треда, синхронно каждый кадр
// Тред не нужен: hitObject живёт один physics-фрейм,
// синхронная запись попадает точнее чем спящий воркер
void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    uint64_t target      = g_SilentBestTarget;
    if (!isVaildPtr(localPlayer) || !isVaildPtr(target)) return;

    Vector3 targetPos = GetHeadPosition(target);
    if (IsZeroVec3(targetPos)) return;

    Vector3 localPos = GetHeadPosition(localPlayer);

    for (uint64_t slotOff : kHitObjSlots) {
        uint64_t hitObjPtr = ReadAddr<uint64_t>(localPlayer + slotOff);
        if (!isVaildPtr(hitObjPtr)) continue;

        // Берём origin — откуда летит пуля
        Vector3 origin = ReadAddr<Vector3>(hitObjPtr + kHitObj_Origin);
        if (IsZeroVec3(origin)) origin = localPos;

        // Направление от origin к голове цели — нормализованный вектор
        Vector3 dir = {
            targetPos.x - origin.x,
            targetPos.y - origin.y,
            targetPos.z - origin.z
        };
        float lenSq = dir.x*dir.x + dir.y*dir.y + dir.z*dir.z;
        if (lenSq < 0.0001f) continue;
        float inv = 1.0f / std::sqrt(lenSq);
        dir.x *= inv;
        dir.y *= inv;
        dir.z *= inv;

        // Перенаправляем пулю — только direction и hitPos
        // 0x5C НЕ трогаем — это damage/distance поле, сброс в 0 крашит
        WriteAddr<Vector3>(hitObjPtr + kHitObj_Direction, dir);
        WriteAddr<Vector3>(hitObjPtr + kHitObj_HitPos,    targetPos);
    }
}

// Оставляем для совместимости с silent.h
void InitSilentAimThread() {
    // Тред не нужен — RunSilentAim синхронный
}
