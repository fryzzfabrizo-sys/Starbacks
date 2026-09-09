#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"
#include <mutex>
#include <thread>
#include <chrono>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// Все GMPGMPFNMFP слоты на Player (OB54) — включая гранаты и скиллы
static constexpr uint64_t kSlots[] = {
    0xA90, 0xAA0,               // m_hitObjInfo / m_touchObjectInfo
    0xDC8, 0xDD0,               // m_LastAimingInfoFromWeapon (regular / MaxGame)
    0x15F0, 0x1760,             // skill / special slots
    0x1A88,                     // grenade slot
    0x2130, 0x21D8              // extra slots
};
static constexpr int kSlotCount = sizeof(kSlots)/sizeof(kSlots[0]);

static std::mutex  silentLock;
static uint64_t    g_local     = 0;
static Vector3     g_TargetPos = {0,0,0};
static bool        g_HasData   = false;
static uint64_t    g_lastLocal = 0;

static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t h = getHead(pawn);
    return isVaildPtr(h) ? getPositionExt(h) : Vector3{};
}

static void AimSilentThread() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::nanoseconds(1));
        if (!g_HasData) continue;

        silentLock.lock();
        uint64_t local = g_local;
        Vector3  tPos  = g_TargetPos;
        bool     valid = g_HasData;
        silentLock.unlock();

        if (!valid || !isVaildPtr(local)) continue;

        // Пишем во все слоты без исключения
        for (int i = 0; i < kSlotCount; i++) {
            uint64_t h = ReadAddr<uint64_t>(local + kSlots[i]);
            if (!isVaildPtr(h)) continue;

            Vector3 base = ReadAddr<Vector3>(h + 0x4C); // StartPosition
            if (base.x == 0 && base.y == 0 && base.z == 0)
                base = ReadAddr<Vector3>(local + 0x100); // fallback: local pos

            Vector3 dir = { tPos.x-base.x, tPos.y-base.y, tPos.z-base.z };
            float len = dir.x*dir.x + dir.y*dir.y + dir.z*dir.z;
            if (len < 0.0001f) continue;
            float inv = 1.f/__builtin_sqrtf(len);
            dir.x *= inv; dir.y *= inv; dir.z *= inv;

            WriteAddr<Vector3>(h + 0x40, dir);  // RayDir
            WriteAddr<Vector3>(h + 0x28, tPos); // HitLocation
            WriteAddr<float>  (h + 0x5C, 0.f);  // scatter = 0
        }
    }
}

void InitSilentAimThread() {
    static bool started = false;
    if (!started) { started = true; std::thread(AimSilentThread).detach(); }
}

void RunSilentAim() {
    if (!aimsilent1) {
        silentLock.lock(); g_HasData = false; g_local = 0; silentLock.unlock();
        return;
    }
    if (!isVaildPtr(cachedMatch)) return;

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local)) return;

    if (local != g_lastLocal) {
        g_lastLocal = local;
        silentLock.lock(); g_HasData = false; g_local = 0; silentLock.unlock();
        return;
    }

    uint64_t enemy = isVaildPtr(g_SilentBestTarget) ? g_SilentBestTarget : 0;
    if (!enemy) {
        silentLock.lock(); g_HasData = false; silentLock.unlock();
        return;
    }

    Vector3 tPos = GetHeadPosition(enemy);
    if (tPos.x == 0 && tPos.y == 0 && tPos.z == 0) {
        silentLock.lock(); g_HasData = false; silentLock.unlock();
        return;
    }

    silentLock.lock();
    g_local    = local;
    g_TargetPos = tPos;
    g_HasData  = true;
    silentLock.unlock();
}

void ResetSilentAim() {
    silentLock.lock(); g_HasData = false; g_local = 0; silentLock.unlock();
    g_lastLocal = 0;
}
