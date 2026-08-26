#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// OB54 подтверждённые оффсеты (из OB53 dump + OB54 сверка)
static constexpr uint64_t kPlayer_sAim1   = 0x7D8; // bool IFCJGLEOGDD — game's own silent aim flag
static constexpr uint64_t kPlayer_AimInfo = 0xDC8; // GMPGMPFNMFP AKFLHNOIHED — AimInfo ptr
static constexpr uint64_t kAim_RayDir     = 0x40;  // Vector3 IKDEGKIICJP — bullet direction
static constexpr uint64_t kAim_StartPos   = 0x4C;  // Vector3 LMAEGPEAECO — muzzle position
static constexpr uint64_t kWpn_CostAmmo   = 0x7B8; // bool m_CostAmmo — гранаты/IceWall = false

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) return;

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) return;

    // Гранаты и IceWall не тратят ammo — не трогаем
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) return;

    Vector3 headPos = HeadPos(target);
    if (headPos.x == 0.0f && headPos.y == 0.0f && headPos.z == 0.0f) return;

    Vector3 localPos = HeadPos(local);

    // Направление к голове врага
    Vector3 diff = { headPos.x - localPos.x,
                     headPos.y - localPos.y,
                     headPos.z - localPos.z };
    float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
    if (lenSq <= 0.0001f) return;

    float   inv = 1.0f / std::sqrt(lenSq);
    Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };

    // Включаем встроенный silent aim флаг игры
    WriteAddr<bool>(local + kPlayer_sAim1, true);

    // Читаем AimInfo pointer и пишем направление
    uint64_t aimInfo = ReadAddr<uint64_t>(local + kPlayer_AimInfo);
    if (!isVaildPtr(aimInfo)) return;

    WriteAddr<Vector3>(aimInfo + kAim_RayDir,   dir);
    WriteAddr<Vector3>(aimInfo + kAim_StartPos,  localPos);
}

// Сбрасываем sAim1 когда silent выключен
void ResetSilentAim() {
    if (!isVaildPtr(cachedMatch)) return;
    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local)) return;
    WriteAddr<bool>(local + kPlayer_sAim1, false);
}

void InitSilentAimThread() {}
