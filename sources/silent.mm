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
extern uint64_t Moudule_Base;   // <-- добавлено

// Константы для работы со словарём игроков (если не определены в GameLogic.h)
#ifndef kMatchPlayerDict
#define kMatchPlayerDict       0x???  // подставьте реальные оффсеты
#define kDictCount             0x???
#define kDictEntries           0x???
#define kIl2CppArrayMaxLength  0x???
#define kDictEntryStrideBytePlayer 0x???
#define kDictEntryValueOffByte     0x???
#endif

// OB54 offsets (подтверждено OB53 dump + Il2CppGetFieldOffset из txt)
static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8; // GEGFCFDGGGP = m_LastAimingInfoFromWeapon
static constexpr uint64_t kHit_RayDir         = 0x40;  // NHKKHPLFMNG — НЕ нормализуем!
static constexpr uint64_t kHit_StartPos       = 0x4C;  // BOGOIAMJFDN
static constexpr uint64_t kWpn_CostAmmo       = 0x7B8;

static std::atomic<bool>     g_hasData{false};
static std::atomic<bool>     g_started{false};
static std::atomic<uint64_t> g_aimPtr {0};
static std::atomic<uint64_t> g_target {0};
static std::atomic<uint64_t> g_local  {0};

static inline bool isValidIOSPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ===== НОВАЯ ФУНКЦИЯ: проверка принадлежности игрока матчу =====
static bool IsPlayerInMatch(uint64_t player, uint64_t match) {
    if (!isVaildPtr(match) || !isVaildPtr(player)) return false;
    uint64_t playerDict = ReadAddr<uint64_t>(match + kMatchPlayerDict);
    if (!isVaildPtr(playerDict)) return false;
    int dictCount = ReadAddr<int>(playerDict + kDictCount);
    if (dictCount <= 0) return false;
    uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
    if (!isVaildPtr(entriesArr)) return false;
    int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
    if (slotCap <= 0) return false;
    uint64_t base = entriesArr + kIl2CppArrayItems;
    for (int i = 0; i < slotCap; i++) {
        uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
        if (ReadAddr<int>(ent) == 0) continue;
        uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
        if (pawn == player) return true;
    }
    return false;
}
// ==============================================================

static void SilentWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_hasData.load(std::memory_order_acquire)) continue;

        uint64_t h      = g_aimPtr.load(std::memory_order_relaxed);
        uint64_t target = g_target.load(std::memory_order_relaxed);
        uint64_t local  = g_local.load(std::memory_order_relaxed);
        if (!isValidIOSPtr(h) || !isVaildPtr(target)) continue;

        // ===== ДОПОЛНИТЕЛЬНАЯ ПРОВЕРКА: цель жива? =====
        if (get_CurHP(target) <= 0) {
            g_hasData.store(false, std::memory_order_release);
            continue;
        }
        if (local && get_CurHP(local) <= 0) {
            g_hasData.store(false, std::memory_order_release);
            continue;
        }
        // ===============================================

        Vector3 tPos = HeadPos(target);
        if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) continue;
        tPos.y += 0.05f;

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = HeadPos(local);

        Vector3 dir = {
            tPos.x - origin.x,
            tPos.y - origin.y,
            tPos.z - origin.z
        };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

// ===== ИСПРАВЛЕННАЯ RunSilentAim =====
void RunSilentAim() {
    static uint64_t lastMatch = 0;

    // 1. Получить актуальный матч через глобальный Moudule_Base
    if (Moudule_Base == (uint64_t)-1) {
        ResetSilentAim();
        return;
    }
    uint64_t matchGame = getMatchGame(Moudule_Base);
    if (!isVaildPtr(matchGame)) {
        ResetSilentAim();
        return;
    }
    uint64_t currentMatch = getMatch(matchGame);
    if (!isVaildPtr(currentMatch)) {
        ResetSilentAim();
        return;
    }

    // 2. Если матч сменился – сбросить всё состояние
    if (currentMatch != lastMatch) {
        ResetSilentAim();
        lastMatch = currentMatch;
        cachedMatch = currentMatch; // обновить глобальную переменную
    }

    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(currentMatch)) {
        ResetSilentAim();
        return;
    }

    uint64_t local = getLocalPlayer(currentMatch);
    uint64_t target = g_SilentBestTarget;

    // 3. Проверить, что цель действительно принадлежит текущему матчу
    if (!isVaildPtr(target) || !IsPlayerInMatch(target, currentMatch)) {
        g_SilentBestTarget = 0;  // сбросить глобальную цель
        ResetSilentAim();
        return;
    }

    if (!isVaildPtr(local) || get_CurHP(local) <= 0) {
        ResetSilentAim();
        return;
    }

    // 4. Проверка оружия (гранаты / IceWall)
    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        ResetSilentAim();
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!isValidIOSPtr(aimPtr)) {
        ResetSilentAim();
        return;
    }

    // 5. Обновить атомарные переменные для рабочего потока
    g_aimPtr.store(aimPtr, std::memory_order_relaxed);
    g_target.store(target, std::memory_order_relaxed);
    g_local .store(local,  std::memory_order_relaxed);
    g_hasData.store(true,  std::memory_order_release);
}
// ====================================

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_aimPtr.store(0,  std::memory_order_relaxed);
    g_target.store(0,  std::memory_order_relaxed);
    g_local .store(0,  std::memory_order_relaxed);
}
