#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/ESPPrefs.h"
#import "mahoa.h"
#include <mutex>
#include <thread>
#include <chrono>

// ─── Extern: bestTarget được promote lên file scope trong esp.mm ───
// GetClosestEnemysilent1() đọc thẳng từ đó — không cần pass thêm.
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

// ─── Shared state giữa main thread và background thread ───────────
static std::mutex  silentLock;
static void       *g_HitObjInfo = nullptr;
static Vector3     g_TargetPos  = {0.0f, 0.0f, 0.0f};
static bool        g_HasData    = false;

// ─── Helper: lấy enemy gần nhất từ g_SilentBestTarget ─────────────
static uint64_t GetClosestEnemysilent1() {
    if (!isVaildPtr(g_SilentBestTarget)) return 0;
    return g_SilentBestTarget;
}

// ─── Helper: lấy vị trí đầu địch ─────────────────────────────────
static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

// ─── Background thread: redirect trajectory của viên đạn ──────────
// Đọc HitObjectInfo từ shared state, ghi lại direction và target pos.
// offset +0x4C: vị trí gốc viên đạn (ammo base)
// offset +0x40: direction vector (ghi đè)
// offset +0x28: target position  (ghi đè)
static void AimSilentThread() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(1));
        if (!g_HasData) continue;

        silentLock.lock();
        void   *currentHitObj = g_HitObjInfo;
        Vector3 targetPos     = g_TargetPos;
        bool    valid         = g_HasData;
        silentLock.unlock();

        if (!valid || !currentHitObj) continue;

        // Đọc vị trí gốc viên đạn
        Vector3 ammoBase = *(Vector3 *)((uint64_t)currentHitObj + 0x4C);

        // Tính direction vector: target − origin
        Vector3 dir;
        dir.x = targetPos.x - ammoBase.x;
        dir.y = targetPos.y - ammoBase.y;
        dir.z = targetPos.z - ammoBase.z;

        // Ghi đè direction và target vào HitObjectInfo
        *(Vector3 *)((uint64_t)currentHitObj + 0x40) = dir;
        *(Vector3 *)((uint64_t)currentHitObj + 0x28) = targetPos;
    }
}

// ─── Gọi mỗi frame từ renderESPWithBuffers ────────────────────────
void RunSilentAim() {
    // Feature tắt → flush data
    if (!aimsilent1) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData    = false;
            g_HitObjInfo = nullptr;
            silentLock.unlock();
        }
        return;
    }

    if (!isVaildPtr(cachedMatch)) return;

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(localPlayer)) return;

    // Chỉ chạy khi đang bắn
    if (!get_IsFiring(localPlayer)) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData    = false;
            g_HitObjInfo = nullptr;
            silentLock.unlock();
        }
        return;
    }

    uint64_t closestEnemy = GetClosestEnemysilent1();
    if (!closestEnemy) {
        if (g_HasData) {
            silentLock.lock();
            g_HasData    = false;
            g_HitObjInfo = nullptr;
            silentLock.unlock();
        }
        return;
    }

    // Đọc HitObjectInfo từ local player + 0xDC8
    void *hitObjInfo = *(void **)((uint64_t)localPlayer + 0xDC8);
    if (!hitObjInfo) return;

    Vector3 enemyHeadPos = GetHeadPosition(closestEnemy);

    silentLock.lock();
    g_HitObjInfo = hitObjInfo;
    g_TargetPos  = enemyHeadPos;
    g_HasData    = true;
    silentLock.unlock();
}

// ─── Gọi 1 lần khi HUD khởi động ─────────────────────────────────
void InitSilentAimThread() {
    std::thread(AimSilentThread).detach();
}
