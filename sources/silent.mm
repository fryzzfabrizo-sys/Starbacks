#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Заглушки — вызываются из esp.mm, но поток больше не нужен
void InitSilentAimThread() { }
void ResetSilentAim()      { }

// Вызывается СИНХРОННО из updateFrame (60 fps) — без потоков.
// Пишем направление каждый кадр, поэтому одиночные выстрелы тоже перехватываются.
void RunSilentAim() {
    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch))
        return;

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local))
        return;

    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(target))
        return;

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr))
        return;

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f)
        return;

    tPos.y += 0.05f;

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
        origin = HeadPos(local);

    Vector3 diff = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
    float lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
    if (lenSq <= 0.0001f)
        return;

    float   inv = 1.0f / std::sqrt(lenSq);
    Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

    WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
}
