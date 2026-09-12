#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_Scatter        = 0x5C;

// ── WALL BANG ─────────────────────────────────────────────
// Дистанция от головы цели, куда ставим новый origin.
// 1.5 = компромисс: raycast не начинается в стене,
// но и не так далеко, чтобы античит понял "origin не у игрока".
static constexpr float kWallBangOriginDist = 1.5f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<bool> g_wallBangEnabled{false};   // toggle

static uint64_t          g_aimPtr         = 0;
static Vector3           g_tPos           = {};
static Vector3           g_lPos           = {};
static Vector3           g_prevTargetPos  = {};
static Vector3           g_targetVelocity = {};

static uint64_t          g_lastLocal  = 0;
static uint64_t          g_lastTarget = 0;
static uint64_t          g_lastMatch  = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  WORKER
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            lPos = g_lPos;
            vel  = g_targetVelocity;
        }
        if (!validPtr(h)) continue;

        // Предсказание
        Vector3 predPos = {
            tPos.x + vel.x * 0.06f,
            tPos.y + vel.y * 0.06f,
            tPos.z + vel.z * 0.06f
        };

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        // ═══ WALL BANG ═══
        if (g_wallBangEnabled.load(std::memory_order_relaxed)) {
            // Вектор от игрока к цели
            float dx = predPos.x - lPos.x;
            float dy = predPos.y - lPos.y;
            float dz = predPos.z - lPos.z;
            float dist = std::sqrt(dx*dx + dy*dy + dz*dz);

            if (dist > 0.5f) {
                float invD = 1.0f / dist;
                float nx = dx * invD;
                float ny = dy * invD;
                float nz = dz * invD;

                // Новый origin: рядом с головой цели, со стороны игрока
                origin.x = predPos.x - nx * kWallBangOriginDist;
                origin.y = predPos.y - ny * kWallBangOriginDist;
                origin.z = predPos.z - nz * kWallBangOriginDist;

                // Перезаписываем origin в памяти
                WriteAddr<Vector3>(h + kHit_StartPos, origin);
            }
        }

        // Направление от (нового) origin к цели
        Vector3 diff  = { predPos.x - origin.x, predPos.y - origin.y, predPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
        WriteAddr<float>(h + kHit_Scatter, 0.0f);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastLocal      = 0;
    g_lastTarget     = 0;
    g_prevTargetPos  = {};
    g_targetVelocity = {};
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
}

// Публичное API
extern "C" void SetWallBang(bool on) { g_wallBangEnabled.store(on); }
extern "C" bool GetWallBang()        { return g_wallBangEnabled.load(); }

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        g_lastMatch = 0;
        ResetSilentAim();
        return;
    }

    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0.0f && tPos.y == 0.0f && tPos.z == 0.0f) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos  = {};
        g_targetVelocity = {};
        return;
    }

    // Скорость цели
    if (g_prevTargetPos.x != 0.0f || g_prevTargetPos.y != 0.0f || g_prevTargetPos.z != 0.0f) {
        Vector3 delta = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
        float distSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
        if (distSq < 25.0f) {
            g_targetVelocity = delta;
        } else {
            g_targetVelocity = {0.0f, 0.0f, 0.0f};
        }
    } else {
        g_targetVelocity = {0.0f, 0.0f, 0.0f};
    }
    g_prevTargetPos = tPos;

    tPos.y += 0.05f;

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
        g_lPos   = lPos;
    }
    g_hasData.store(true, std::memory_order_release);

    // ═══ Мгновенный пинг — с Wall Bang ═══
    if (validPtr(aimPtr)) {
        // База
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f)
            origin = lPos;

        // Wall Bang
        if (g_wallBangEnabled.load(std::memory_order_relaxed)) {
            float dx = tPos.x - lPos.x;
            float dy = tPos.y - lPos.y;
            float dz = tPos.z - lPos.z;
            float dist = std::sqrt(dx*dx + dy*dy + dz*dz);

            if (dist > 0.5f) {
                float invD = 1.0f / dist;
                origin.x = tPos.x - (dx * invD) * kWallBangOriginDist;
                origin.y = tPos.y - (dy * invD) * kWallBangOriginDist;
                origin.z = tPos.z - (dz * invD) * kWallBangOriginDist;
                WriteAddr<Vector3>(aimPtr + kHit_StartPos, origin);
            }
        }

        Vector3 diff  = { tPos.x - origin.x, tPos.y - origin.y, tPos.z - origin.z };
        float   lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq > 0.0001f) {
            float   inv = 1.0f / std::sqrt(lenSq);
            Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };
            WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
            WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);
        }
    }
}
