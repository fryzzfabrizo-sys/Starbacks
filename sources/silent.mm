#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>

extern uint64_t g_SilentBestTarget; // лучшая цель, выбранная в renderESPWithBuffers
extern uint64_t cachedMatch;        // текущий матч
extern bool     aimsilent1;         // флаг включения Silent Aim

// Смещения (те же, что и были)
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // m_LastAimingInfoFromWeapon
static constexpr uint64_t kHit_RayDir         = 0x40;  // Vector3 RayDir
static constexpr uint64_t kHit_StartPos       = 0x4C;  // Vector3 StartPosition
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

// Получение позиции головы (обёртка)
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ─── Основная функция Silent Aim (синхронная) ─────────────────────
void RunSilentAim() {
    // Если Silent Aim выключен или нет матча – выходим
    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        return;
    }

    // Локальный игрок и цель
    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        return;
    }

    // Проверка оружия: если есть оружие и у него costAmmo == false (бесконечные патроны?) – не трогаем
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        return;
    }

    // Указатель на структуру последнего прицеливания
    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isVaildPtr(aimPtr)) {
        return;
    }

    // Позиция головы цели
    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        return;
    }

    // Получаем точку старта луча. Если StartPos нулевая – используем позицию головы локального игрока.
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f) {
        origin = HeadPos(local);
    }

    // Вычисляем вектор направления
    Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
    float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
    if (lenSq <= 0.0001f) return; // слишком близко

    float   inv = 1.0f / std::sqrt(lenSq);
    Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

    // Записываем направление сразу в структуру прицеливания
    WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
}

// ─── Заглушка для совместимости (раньше сбрасывала поток) ─────────
void ResetSilentAim() {
    // Ничего не делаем: состояние потока отсутствует.
    // Можно вообще убрать вызов, но оставим для обратной совместимости.
}
