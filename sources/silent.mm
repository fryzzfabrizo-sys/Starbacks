#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool aimsilent1;

// GMPGMPFNMFP — HitObjectInfo (из dump.cs, подтверждено)
// player + slot → ptr → GMPGMPFNMFP object
static constexpr uint64_t kHitObjSlots[] = { 0xA90, 0xAA0, 0xDC8, 0xDD0 };

// Field offsets (GMPGMPFNMFP → HitObjectInfo)
static constexpr uint64_t kHit_HitObject      = 0x18; // GameObject HLIJMDODPIM
static constexpr uint64_t kHit_HitCollider    = 0x20; // Collider    OCEBCHENIOK
static constexpr uint64_t kHit_HitLocation    = 0x28; // Vector3     MBGBCLNJOMK
static constexpr uint64_t kHit_HitNormal      = 0x34; // Vector3     DGFLGBEOGPG
static constexpr uint64_t kHit_RayDir         = 0x40; // Vector3     IKDEGKIICJP
static constexpr uint64_t kHit_StartPosition  = 0x4C; // Vector3     LMAEGPEAECO
static constexpr uint64_t kHit_Distance       = 0x5C; // float       PGCPFOAJHBM
static constexpr uint64_t kHit_HitGroup       = 0x64; // JKCLPFEFMNG FLCLOHCBJEI (0=Default,1=Head,2=Body)
static constexpr uint64_t kHit_IgnoreHappens  = 0x70; // bool        DEDOKPCAHAC
static constexpr uint64_t kHit_ViewBlocked    = 0x71; // bool        GGJOADOBLID
static constexpr uint64_t kHit_OrigStart      = 0x74; // Vector3     KPEICEMCHIF
static constexpr uint64_t kHit_SpecialHitType = 0x80; // short       LNOIFBAFGOK

// Cached collider на Enemy: protected Collider NFDNMIOPILM; // 0x6D0
static constexpr uint64_t kEnemy_BodyCollider = 0x6D0;

static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

static inline bool IsZeroVec3(const Vector3& v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static inline float Vec3Len(const Vector3& v) {
    return std::sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
}

static inline Vector3 Vec3Norm(Vector3 v) {
    float inv = 1.0f / (Vec3Len(v) + 1e-6f);
    return { v.x*inv, v.y*inv, v.z*inv };
}

void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    uint64_t target      = g_SilentBestTarget;
    if (!isVaildPtr(localPlayer) || !isVaildPtr(target)) return;

    // Гейт: только при выстреле — IceWall и гранаты не трогаем
    if (!get_IsFiring(localPlayer)) return;

    Vector3 headPos = GetHeadPosition(target);
    if (IsZeroVec3(headPos)) return;

    // Читаем collider тела врага — нужен чтобы сервер зарегал хит на него
    uint64_t enemyCollider  = ReadAddr<uint64_t>(target + kEnemy_BodyCollider);
    // GameObject врага — первые 8 байт после monitor в collider component
    // В Unity IL2CPP Component.m_CachedPtr указывает на нативный объект,
    // но GameObject ссылка хранится через get_gameObject. Оставляем HitObject
    // без изменений — сервер определяет владельца по HitCollider.
    
    for (uint64_t slotOff : kHitObjSlots) {
        uint64_t hitPtr = ReadAddr<uint64_t>(localPlayer + slotOff);
        if (!isVaildPtr(hitPtr)) continue;

        // Читаем оригинальный StartPosition (muzzle/camera origin)
        Vector3 origin = ReadAddr<Vector3>(hitPtr + kHit_StartPosition);
        if (IsZeroVec3(origin)) origin = GetHeadPosition(localPlayer);

        // Нормализованное направление от origin до головы врага
        Vector3 dir = Vec3Norm({
            headPos.x - origin.x,
            headPos.y - origin.y,
            headPos.z - origin.z
        });

        float dist = Vec3Len({
            headPos.x - origin.x,
            headPos.y - origin.y,
            headPos.z - origin.z
        });

        // Полный набор полей — как в SILENT.h
        if (isVaildPtr(enemyCollider)) {
            WriteAddr<uint64_t>(hitPtr + kHit_HitCollider,   enemyCollider);
        }
        WriteAddr<Vector3>(hitPtr + kHit_HitLocation,    headPos);
        WriteAddr<Vector3>(hitPtr + kHit_HitNormal,       headPos);
        WriteAddr<Vector3>(hitPtr + kHit_RayDir,          dir);
        WriteAddr<float>  (hitPtr + kHit_Distance,        dist);
        WriteAddr<int32_t>(hitPtr + kHit_HitGroup,        1);       // Head
        WriteAddr<bool>   (hitPtr + kHit_IgnoreHappens,   false);
        WriteAddr<bool>   (hitPtr + kHit_ViewBlocked,     false);
        WriteAddr<Vector3>(hitPtr + kHit_OrigStart,       origin);
        WriteAddr<int16_t>(hitPtr + kHit_SpecialHitType,  0);
    }
}

void InitSilentAimThread() {}
