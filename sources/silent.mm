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

static constexpr uint64_t kPlayer_LastAimInfo  = 0xDC8;
static constexpr uint64_t kPlayer_AimRotation  = 0x5AC; // Quaternion m_AimRotation
static constexpr uint64_t kPlayer_AuxAimRot    = 0x5BC; // Quaternion m_AuxAimRotation
static constexpr uint64_t kHit_RayDir          = 0x40;
static constexpr uint64_t kHit_StartPos        = 0x4C;
static constexpr uint64_t kWpn_CostAmmo        = 0x7B8;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_local         = 0;
static uint64_t          g_aimPtr        = 0;
static Vector3           g_tPos          = {};
static Vector3           g_lPos          = {};
static Vector3           g_prevTargetPos = {};
static Vector3           g_targetVelocity= {};
static uint64_t          g_lastLocal     = 0;

// LookRotation: Vector3 forward → Quaternion
static Quaternion LookRotation(Vector3 forward) {
    float len = std::sqrt(forward.x*forward.x + forward.y*forward.y + forward.z*forward.z);
    if (len < 1e-6f) return {0,0,0,1};
    forward.x /= len; forward.y /= len; forward.z /= len;

    Vector3 up = {0,1,0};
    Vector3 right = {
        up.y*forward.z - up.z*forward.y,
        up.z*forward.x - up.x*forward.z,
        up.x*forward.y - up.y*forward.x
    };
    float rLen = std::sqrt(right.x*right.x + right.y*right.y + right.z*right.z);
    if (rLen < 1e-6f) { right = {1,0,0}; rLen = 1; }
    right.x /= rLen; right.y /= rLen; right.z /= rLen;

    Vector3 u = {
        forward.y*right.z - forward.z*right.y,
        forward.z*right.x - forward.x*right.z,
        forward.x*right.y - forward.y*right.x
    };

    float m00=right.x, m11=u.y, m22=forward.z;
    float tr = m00 + m11 + m22;
    Quaternion q;
    if (tr > 0) {
        float s = std::sqrt(tr+1)*2;
        q.w = 0.25f*s;
        q.x = (u.z - forward.y)/s;
        q.y = (forward.x - right.z)/s;
        q.z = (right.y - u.x)/s;
    } else if (m00 > m11 && m00 > m22) {
        float s = std::sqrt(1+m00-m11-m22)*2;
        q.w = (u.z - forward.y)/s;
        q.x = 0.25f*s;
        q.y = (right.y + u.x)/s;
        q.z = (forward.x + right.z)/s;
    } else if (m11 > m22) {
        float s = std::sqrt(1+m11-m00-m22)*2;
        q.w = (forward.x - right.z)/s;
        q.x = (right.y + u.x)/s;
        q.y = 0.25f*s;
        q.z = (u.z + forward.y)/s;
    } else {
        float s = std::sqrt(1+m22-m00-m11)*2;
        q.w = (right.y - u.x)/s;
        q.x = (forward.x + right.z)/s;
        q.y = (u.z + forward.y)/s;
        q.z = 0.25f*s;
    }
    return q;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t local, h;
        Vector3  tPos, lPos, vel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            local = g_local;
            h     = g_aimPtr;
            tPos  = g_tPos;
            lPos  = g_lPos;
            vel   = g_targetVelocity;
        }
        if (!isVaildPtr(local)) { g_hasData.store(false, std::memory_order_release); continue; }

        // Предсказание движения
        Vector3 pred = { tPos.x + vel.x*0.06f, tPos.y + vel.y*0.06f, tPos.z + vel.z*0.06f };

        // ── Подход 1: m_AimRotation ──────────────────────────────────────
        // Пишем Quaternion — игра САМА делает raycast в этом направлении
        // HitCollider будет реальным (враг попал) → сервер принимает
        // Камера дернется на ~1 кадр, но пули точные и сервер доволен
        Vector3 fwd = { pred.x - lPos.x, pred.y - lPos.y, pred.z - lPos.z };
        Quaternion q = LookRotation(fwd);
        WriteAddr<Quaternion>(local + kPlayer_AimRotation, q);
        WriteAddr<Quaternion>(local + kPlayer_AuxAimRot,   q);

        // ── Подход 2: RayDir в hitObject (backup) ────────────────────────
        if (isVaildPtr(h)) {
            Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
            if (origin.x == 0 && origin.y == 0 && origin.z == 0) origin = lPos;
            Vector3 diff = { pred.x-origin.x, pred.y-origin.y, pred.z-origin.z };
            float len = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
            if (len > 0.0001f) {
                float inv = 1.0f / std::sqrt(len);
                WriteAddr<Vector3>(h + kHit_RayDir, {diff.x*inv, diff.y*inv, diff.z*inv});
            }
        }
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos = {}; g_targetVelocity = {};
        return;
    }

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos = {}; g_targetVelocity = {};
        return;
    }

    // Фикс второго матча
    if (local != g_lastLocal) {
        g_lastLocal = local;
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos = {}; g_targetVelocity = {};
        { std::lock_guard<std::mutex> lk(g_lock); g_aimPtr = 0; g_local = 0; }
        return;
    }

    uint64_t wpn = WeaponOnHand(local);
    if (isVaildPtr(wpn) && !ReadAddr<bool>(wpn + kWpn_CostAmmo)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    // aimPtr может быть 0 — продолжаем, m_AimRotation всё равно пишем

    Vector3 tPos = HeadPos(target);
    if (tPos.x == 0 && tPos.y == 0 && tPos.z == 0) {
        g_hasData.store(false, std::memory_order_release);
        g_prevTargetPos = {}; g_targetVelocity = {};
        return;
    }

    // Скорость цели
    if (g_prevTargetPos.x != 0 || g_prevTargetPos.y != 0 || g_prevTargetPos.z != 0) {
        g_targetVelocity = {
            tPos.x - g_prevTargetPos.x,
            tPos.y - g_prevTargetPos.y,
            tPos.z - g_prevTargetPos.z
        };
    } else {
        g_targetVelocity = {};
    }
    g_prevTargetPos = tPos;
    tPos.y += 0.05f;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_local  = local;
        g_aimPtr = isVaildPtr(aimPtr) ? aimPtr : 0;
        g_tPos   = tPos;
        g_lPos   = HeadPos(local);
    }
    g_hasData.store(true, std::memory_order_release);
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastLocal = 0;
    g_prevTargetPos = {}; g_targetVelocity = {};
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0; g_local = 0;
}
