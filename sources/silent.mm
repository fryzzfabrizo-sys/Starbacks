#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool aimsilent1;

static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(localPlayer) || !get_IsFiring(localPlayer)) return;

    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(target)) return;

    uint64_t hitObjInfo = ReadAddr<uint64_t>(localPlayer + 0xDC8);
    if (!isVaildPtr(hitObjInfo)) return;

    Vector3 targetPos = GetHeadPosition(target);
    if (targetPos.x == 0.0f && targetPos.y == 0.0f && targetPos.z == 0.0f) return;

    Vector3 ammoBase = ReadAddr<Vector3>(hitObjInfo + 0x4C);
    Vector3 direction = {
        targetPos.x - ammoBase.x,
        targetPos.y - ammoBase.y,
        targetPos.z - ammoBase.z
    };

    const float lengthSquared =
        direction.x * direction.x +
        direction.y * direction.y +
        direction.z * direction.z;
    if (lengthSquared <= 0.0001f) return;

    const float inverseLength = 1.0f / std::sqrt(lengthSquared);
    direction.x *= inverseLength;
    direction.y *= inverseLength;
    direction.z *= inverseLength;

    WriteAddr<Vector3>(hitObjInfo + 0x40, direction);
    WriteAddr<Vector3>(hitObjInfo + 0x28, targetPos);
}

void InitSilentAimThread() {
}
