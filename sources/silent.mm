#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool aimsilent1;

// GMPGMPFNMFP (HitObjectInfo) field offsets — из dump.cs
static constexpr uint64_t kHitObjSlots[] = { 0xA90, 0xAA0, 0xDC8, 0xDD0 };

static constexpr uint64_t kHit_HitCollider   = 0x20;
static constexpr uint64_t kHit_HitLocation   = 0x28;
static constexpr uint64_t kHit_HitNormal     = 0x34;
static constexpr uint64_t kHit_RayDir        = 0x40;
static constexpr uint64_t kHit_StartPosition = 0x4C;
static constexpr uint64_t kHit_Distance      = 0x5C;
static constexpr uint64_t kHit_HitGroup      = 0x64; // 1 = Head
static constexpr uint64_t kHit_IgnoreHappens = 0x70;
static constexpr uint64_t kHit_ViewBlocked   = 0x71;
static constexpr uint64_t kHit_OrigStart     = 0x74;
static constexpr uint64_t kHit_SpecialType   = 0x80;

// Enemy body collider
static constexpr uint64_t kEnemy_BodyCollider = 0x6D0;

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static float Len3(Vector3 v) {
    return std::sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
}

static Vector3 Norm3(Vector3 v) {
    float inv = 1.0f / (Len3(v) + 1e-6f);
    return { v.x*inv, v.y*inv, v.z*inv };
}

static bool IsZero(Vector3 v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) return;

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) return;

    // Проверка оружия: гранаты и IceWall (HandCannonIceWall=19, Grenade=5)
    // не тратят ammo → kWeaponCostAmmo = false → пропускаем
    uint64_t wpn = WeaponOnHand(local);
    if (!isVaildPtr(wpn)) return;
    if (!ReadAddr<bool>(wpn + kWeaponCostAmmo)) return;

    Vector3 headPos = HeadPos(target);
    if (IsZero(headPos)) return;

    uint64_t enemyCollider = ReadAddr<uint64_t>(target + kEnemy_BodyCollider);

    for (uint64_t slot : kHitObjSlots) {
        uint64_t h = ReadAddr<uint64_t>(local + slot);
        if (!isVaildPtr(h)) continue;

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPosition);
        if (IsZero(origin)) origin = HeadPos(local);

        Vector3 diff = { headPos.x - origin.x,
                         headPos.y - origin.y,
                         headPos.z - origin.z };
        float dist = Len3(diff);
        Vector3 dir = Norm3(diff);

        if (isVaildPtr(enemyCollider))
            WriteAddr<uint64_t>(h + kHit_HitCollider,   enemyCollider);
        WriteAddr<Vector3>  (h + kHit_HitLocation,   headPos);
        WriteAddr<Vector3>  (h + kHit_HitNormal,      headPos);
        WriteAddr<Vector3>  (h + kHit_RayDir,         dir);
        WriteAddr<float>    (h + kHit_Distance,       dist);
        WriteAddr<int32_t>  (h + kHit_HitGroup,       1);
        WriteAddr<bool>     (h + kHit_IgnoreHappens,  false);
        WriteAddr<bool>     (h + kHit_ViewBlocked,    false);
        WriteAddr<Vector3>  (h + kHit_OrigStart,      origin);
        WriteAddr<int16_t>  (h + kHit_SpecialType,    0);
    }
}

void InitSilentAimThread() {}
