#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t cachedMatch;
extern bool     aimsilent1;
extern uint64_t g_SilentBestTarget; // перезаписываем здесь

// ======== Оффсеты (из offset.h и Hooks.h) ========
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;


// Четыре слота HitObjectInfo в Player (OB54)
static constexpr uint64_t kHitObjOffs[4] = {
    0xDC8,  // AKFLHNOIHED
    0xDD0,  // PJGMLPMAMGN
    0xA90,  // GGKLDGMAFHN
    0xAA0   // NFKMINKONNC
};

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_localPlayer = 0;
static Vector3           g_targetPos   = {};
static Vector3           g_localPos    = {};

// ======== Вспомогательные функции ========

// Получение forward из кватерниона поворота игрока (ось Z)
static Vector3 GetForwardFromQuaternion(uint64_t player) {
    if (!isVaildPtr(player)) return Vector3{0, 0, 1};
    Quaternion q = ReadAddr<Quaternion>(player + kAimRotation);
    float x = q.x, y = q.y, z = q.z, w = q.w;
    Vector3 fwd;
    fwd.x = 2 * (x*z + w*y);
    fwd.y = 2 * (y*z - w*x);
    fwd.z = 1 - 2 * (x*x + y*y);
    return fwd;
}

// Позиция головы (без смещений)
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t head = getHead(pawn);
    return isVaildPtr(head) ? getPositionExt(head) : Vector3{};
}

// ======== Поток, пишущий RayDir во все 4 слота ========
static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(0));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t local;
        Vector3  tPos, lPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local = g_localPlayer;
            tPos  = g_targetPos;
            lPos  = g_localPos;
        }
        if (!isVaildPtr(local)) continue;

        for (int i = 0; i < 4; ++i) {
            uint64_t hitObj = ReadAddr<uint64_t>(local + kHitObjOffs[i]);
            if (!isVaildPtr(hitObj)) continue;

            Vector3 origin = ReadAddr<Vector3>(hitObj + kHit_StartPos);
            if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
                origin = lPos;

            Vector3 diff = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
            float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
            if (lenSq <= 0.0001f) continue;

            float inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x*inv, diff.y*inv, diff.z*inv };

            WriteAddr<Vector3>(hitObj + kHit_RayDir, dir);
            // НЕ зануляем разброс (0x5C)
        }
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

// ======== Основная функция, вызываемая из esp.mm каждый кадр ========
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        g_SilentBestTarget = 0;
        return;
    }

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local) || get_CurHP(local) <= 0) {
        g_hasData.store(false, std::memory_order_release);
        g_SilentBestTarget = 0;
        return;
    }

    Vector3 forward = GetForwardFromQuaternion(local);
    Vector3 localPos = getPositionExt(getHead(local)); // позиция головы локального

    // Получаем словарь игроков
    uint64_t playerDict = ReadAddr<uint64_t>(cachedMatch + kMatchPlayerDict);
    if (!isVaildPtr(playerDict)) {
        g_hasData.store(false, std::memory_order_release);
        g_SilentBestTarget = 0;
        return;
    }

    int dictCount = ReadAddr<int>(playerDict + kDictCount);
    uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
    if (!isVaildPtr(entriesArr) || dictCount <= 0) {
        g_hasData.store(false, std::memory_order_release);
        g_SilentBestTarget = 0;
        return;
    }

    int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
    if (slotCap <= 0 || slotCap > 256) {
        g_hasData.store(false, std::memory_order_release);
        g_SilentBestTarget = 0;
        return;
    }

    float bestDist = FLT_MAX;
    uint64_t bestTarget = 0;
    Vector3 bestHeadPos = {};

    uint64_t base = entriesArr + kIl2CppArrayItems;
    for (int i = 0; i < slotCap; ++i) {
        uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
        if (ReadAddr<int>(ent) == 0) continue;

        uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
        if (!isVaildPtr(pawn) || pawn == local) continue;
        if (isLocalTeamMate(local, pawn)) continue;

        int hp = get_CurHP(pawn);
        if (hp <= 0) continue;

        // Опционально: игнорировать ботов, даунов, проверять видимость
        // if (IgnoreBots && get_IsBot(pawn)) continue;
        // if (IgnoreDowned && get_IsKnockedDown(pawn)) continue;
        // if (CheckWall && !getIsVisible(pawn)) continue;

        Vector3 headPos = HeadPos(pawn);
        if (headPos.x == 0.0f && headPos.y == 0.0f && headPos.z == 0.0f) continue;

        Vector3 toEnemy = Vector3::Normalized(headPos - localPos);
        float dot = Vector3::Dot(forward, toEnemy);
        if (dot < 0.0f) continue; // цель за спиной

        float dist = Vector3::Distance(localPos, headPos);
        if (dist < bestDist) {
            bestDist = dist;
            bestTarget = pawn;
            bestHeadPos = headPos;
        }
    }

    if (!bestTarget) {
        g_hasData.store(false, std::memory_order_release);
        g_SilentBestTarget = 0;
        return;
    }

    // Проверка гранат / IceWall
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        g_SilentBestTarget = 0;
        return;
    }

    // Обновляем данные для потока
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_localPlayer = local;
        g_targetPos   = bestHeadPos;   // без +0.05
        g_localPos    = HeadPos(local); // fallback
    }
    g_hasData.store(true, std::memory_order_release);
    g_SilentBestTarget = bestTarget; // для совместимости
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_localPlayer = 0;
    g_SilentBestTarget = 0;
}
