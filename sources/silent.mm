Привет есть вот такой сайлент как бы

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// iOS ARM64 OB54 оффсеты (из OB53 dump + сдвиг)
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // m_LastAimingInfoFromWeapon
static constexpr uint64_t kHit_RayDir         = 0x40;  // Vector3 RayDir (только это)
static constexpr uint64_t kHit_StartPos       = 0x4C;  // Vector3 StartPosition (читаем)
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr  = 0;
static Vector3           g_tPos    = {};
static Vector3           g_lPos    = {};

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    // В событийной модели отдельный worker не используется.
    // Обработка должна выполняться непосредственно для
    // конкретного объекта выстрела.
}

void InitSilentAimThread() {
    // Поток больше не требуется.
}

void RunSilentAim() {
    if (!aimsilent1 || !isVaildPtr(cachedMatch))
        return;

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target))
        return;

    // Гранаты и IceWall не тратят ammo
    uint64_t wpn = WeaponOnHand(local);

    if (isVaildPtr(wpn) &&
        !ReadAddr<bool>(wpn + kWpn_CostAmmo))
        return;

    // Получаем актуальный объект текущего выстрела.
    uint64_t aimPtr =
        ReadAddr<uint64_t>(
            local + kPlayer_LastAimInfo
        );

    if (!isVaildPtr(aimPtr))
        return;

    // Получаем StartPosition именно текущего объекта.
    Vector3 origin =
        ReadAddr<Vector3>(
            aimPtr + kHit_StartPos
        );

    if (origin.x == 0.0f &&
        origin.y == 0.0f &&
        origin.z == 0.0f)
        return;

    // Позиция цели получается непосредственно
    // для текущего вызова, а не сохраняется заранее.
    Vector3 tPos = HeadPos(target);

    if (tPos.x == 0.0f &&
        tPos.y == 0.0f &&
        tPos.z == 0.0f)
        return;

    // +0.05 Y — как в исходном варианте.
    tPos.y += 0.05f;

    Vector3 diff = {
        tPos.x - origin.x,
        tPos.y - origin.y,
        tPos.z - origin.z
    };

    float lenSq =
        diff.x * diff.x +
        diff.y * diff.y +
        diff.z * diff.z;

    if (lenSq <= 0.0001f)
        return;

    float inv =
        1.0f / std::sqrt(lenSq);

    Vector3 dir = {
        diff.x * inv,
        diff.y * inv,
        diff.z * inv
    };

    // В псевдомодели здесь происходит изменение
    // направления текущего ray/hit объекта.
    WriteAddr<Vector3>(
        aimPtr + kHit_RayDir,
        dir
    );
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);

    std::lock_guard<std::mutex> lk(g_lock);

    g_aimPtr = 0;
    g_tPos   = {};
    g_lPos   = {};
}
