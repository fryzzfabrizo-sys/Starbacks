#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"

#include <cmath>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// OB54 iOS 64-bit
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool isValidVector(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

static inline bool isZeroVector(const Vector3& v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t head = getHead(pawn);
    if (!isVaildPtr(head)) return {};
    Vector3 pos = getPositionExt(head);
    if (!isValidVector(pos)) return {};
    return pos;
}

static inline bool IsSameMatch(uint64_t match) {
    uint64_t current = cachedMatch;
    if (!isVaildPtr(current) || !isVaildPtr(match)) return false;
    return current == match;
}

// Инициализация не нужна, но оставим пустые функции для совместимости
void InitSilentAimThread() {}
void ShutdownSilentAimThread() {}
void ResetSilentAim() {}

void RunSilentAim() {
    if (!aimsilent1) return;

    uint64_t match = cachedMatch;
    if (!isVaildPtr(match)) return;

    uint64_t local = getLocalPlayer(match);
    if (!isVaildPtr(local)) return;

    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(target)) return;

    if (!IsSameMatch(match)) return;

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn)) {
        bool costAmmo = ReadAddr<bool>(wpn + kWpn_CostAmmo);
        if (!costAmmo) return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isValidIOSPtr(aimPtr)) return;

    // Получаем позицию цели
    Vector3 tPos = HeadPos(target);
    if (!isValidVector(tPos) || isZeroVector(tPos)) return;
    tPos.y += 0.05f;

    // Получаем точку выстрела
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    if (!isValidVector(origin)) return;
    if (isZeroVector(origin)) {
        origin = HeadPos(local);
        if (!isValidVector(origin) || isZeroVector(origin)) return;
    }

    // Вычисляем направление
    Vector3 dir = {
        tPos.x - origin.x,
        tPos.y - origin.y,
        tPos.z - origin.z
    };
    if (!isValidVector(dir) || isZeroVector(dir)) return;

    // Синхронно пишем направление – никаких пропусков
    WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
}
