#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// OB54: m_AimRotation backing field (подтверждено OB53→OB54 сдвиг -8)
static constexpr uint64_t kPlayer_AimRotation    = 0x5AC; // Quaternion <MDCADLIAJIH>
static constexpr uint64_t kPlayer_AuxAimRotation = 0x5BC; // Quaternion <MPNEBFFFAMP>
static constexpr uint64_t kWpn_CostAmmo          = 0x7B8;



static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Unity LookRotation: строим Quaternion из forward вектора
// forward должен быть нормализован
static Quaternion LookRotation(Vector3 forward, Vector3 up = {0.0f, 1.0f, 0.0f}) {
    // Построение ortho basis
    Vector3 f = forward;
    float fLen = std::sqrt(f.x*f.x + f.y*f.y + f.z*f.z);
    if (fLen < 1e-6f) return {0.0f, 0.0f, 0.0f, 1.0f};
    f.x /= fLen; f.y /= fLen; f.z /= fLen;

    // right = up × forward
    Vector3 r = {
        up.y*f.z - up.z*f.y,
        up.z*f.x - up.x*f.z,
        up.x*f.y - up.y*f.x
    };
    float rLen = std::sqrt(r.x*r.x + r.y*r.y + r.z*r.z);
    if (rLen < 1e-6f) {
        r = {1.0f, 0.0f, 0.0f};
    } else {
        r.x /= rLen; r.y /= rLen; r.z /= rLen;
    }

    // actual up = forward × right
    Vector3 u = {
        f.y*r.z - f.z*r.y,
        f.z*r.x - f.x*r.z,
        f.x*r.y - f.y*r.x
    };

    // Rotation matrix → Quaternion
    float m00=r.x, m01=r.y, m02=r.z;
    float m10=u.x, m11=u.y, m12=u.z;
    float m20=f.x, m21=f.y, m22=f.z;

    float tr = m00 + m11 + m22;
    Quaternion q;
    if (tr > 0.0f) {
        float s = std::sqrt(tr + 1.0f) * 2.0f;
        q.w = 0.25f * s;
        q.x = (m12 - m21) / s;
        q.y = (m20 - m02) / s;
        q.z = (m01 - m10) / s;
    } else if (m00 > m11 && m00 > m22) {
        float s = std::sqrt(1.0f + m00 - m11 - m22) * 2.0f;
        q.w = (m12 - m21) / s;
        q.x = 0.25f * s;
        q.y = (m01 + m10) / s;
        q.z = (m20 + m02) / s;
    } else if (m11 > m22) {
        float s = std::sqrt(1.0f + m11 - m00 - m22) * 2.0f;
        q.w = (m20 - m02) / s;
        q.x = (m01 + m10) / s;
        q.y = 0.25f * s;
        q.z = (m12 + m21) / s;
    } else {
        float s = std::sqrt(1.0f + m22 - m00 - m11) * 2.0f;
        q.w = (m01 - m10) / s;
        q.x = (m20 + m02) / s;
        q.y = (m12 + m21) / s;
        q.z = 0.25f * s;
    }
    return q;
}

void InitSilentAimThread() {}

void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) return;

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) return;

    // Гранаты / IceWall
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) return;

    Vector3 headPos   = HeadPos(target);
    Vector3 localPos  = HeadPos(local);
    if (headPos.x == 0.0f && headPos.y == 0.0f && headPos.z == 0.0f) return;
    headPos.y += 0.05f;

    // Направление от игрока к голове врага
    Vector3 forward = {
        headPos.x - localPos.x,
        headPos.y - localPos.y,
        headPos.z - localPos.z
    };

    // Строим Quaternion и пишем в m_AimRotation и m_AuxAimRotation
    Quaternion q = LookRotation(forward);
    WriteAddr<Quaternion>(local + kPlayer_AimRotation,    q);
    WriteAddr<Quaternion>(local + kPlayer_AuxAimRotation, q);
}

void ResetSilentAim() {
    // При выключении — ничего не делаем, игра сама восстановит ротацию
}
