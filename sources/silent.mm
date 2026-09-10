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

// ─── Параметры предсказания ────────────────────
// Полное время от момента нашего расчёта до момента рейкаста игры:
//   1 кадр нашей записи (16 мс) + 1-2 кадра игры до применения (16-32 мс)
// + задержка сетевого тика (в среднем ещё ~16 мс).
static constexpr float kLeadSec          = 0.045f; // ~45 мс вперёд
// Сглаживание скорости (0.0 = мёртвое, 1.0 = без сглаживания).
// Меньше — плавнее, но запаздывает. 0.45 — хороший баланс.
static constexpr float kVelSmoothAlpha   = 0.45f;
// Ограничение сверху на скорость в юнитах/сек (защита от телепорта).
static constexpr float kMaxVel           = 25.0f;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};

static uint64_t          g_aimPtr     = 0;
static Vector3           g_tPos       = {};
static Vector3           g_tVel       = {};
static Vector3           g_lPos       = {};
static Vector3           g_lVel       = {};

static uint64_t          g_lastLocal  = 0;
static uint64_t          g_lastMatch  = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}

static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  WORKER — считает направление с предсказанием позиций.
//  Работает на максимальной частоте, выигрывая гонку с игрой.
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3 tPos, tVel, lPos, lVel;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
            tVel = g_tVel;
            lPos = g_lPos;
            lVel = g_lVel;
        }
        if (!validPtr(h)) continue;

        // ─── 1. Предсказываем позицию цели через kLeadSec ─────
        Vector3 predTarget = {
            tPos.x + tVel.x * kLeadSec,
            tPos.y + tVel.y * kLeadSec,
            tPos.z + tVel.z * kLeadSec
        };

        // ─── 2. Origin читаем свежий из памяти игры ───────────
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) {
            // Fallback — используем последнюю известную позицию + скорость
            origin = {
                lPos.x + lVel.x * kLeadSec,
                lPos.y + lVel.y * kLeadSec,
                lPos.z + lVel.z * kLeadSec
            };
        } else {
            // Origin из памяти уже может быть "сегодняшним" — добавляем
            // только половину lead'а, чтобы не переборщить.
            origin.x += lVel.x * kLeadSec * 0.5f;
            origin.y += lVel.y * kLeadSec * 0.5f;
            origin.z += lVel.z * kLeadSec * 0.5f;
        }

        Vector3 diff = {
            predTarget.x - origin.x,
            predTarget.y - origin.y,
            predTarget.z - origin.z
        };
        float lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) continue;

        float   inv = 1.0f / std::sqrt(lenSq);
        Vector3 dir = { diff.x * inv, diff.y * inv, diff.z * inv };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_lastLocal = 0;
    g_lastMatch = 0;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = 0;
        g_tVel = {}; g_lVel = {};
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — вызывается из updateFrame (60 fps).
//  Считает скорости цели и стрелка, обновляет данные для воркера.
// ═══════════════════════════════════════════════════════════════
static Vector3 s_prevTargetPos = {};
static Vector3 s_prevLocalPos  = {};
static bool    s_havePrevTarget = false;
static bool    s_havePrevLocal  = false;
static std::chrono::steady_clock::time_point s_prevTick;

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        g_lastMatch = 0;
        ResetSilentAim();
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        return;
    }

    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        s_prevTick = std::chrono::steady_clock::now();
        return;
    }

    // ─── Считаем dt с прошлого кадра ──────────────────────
    auto now = std::chrono::steady_clock::now();
    float dt = std::chrono::duration<float>(now - s_prevTick).count();
    s_prevTick = now;
    if (dt <= 0.001f || dt > 0.25f) dt = 0.016f; // защита от спайков

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        s_havePrevTarget = false;
        s_havePrevLocal  = false;
        return;
    }

    Vector3 tPos = HeadPos(target);
    Vector3 lPos = HeadPos(local);
    if (isZeroV3(tPos) || isZeroV3(lPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // ─── Скорость цели (с сглаживанием EMA) ───────────────
    Vector3 newTVel = {0, 0, 0};
    if (s_havePrevTarget) {
        newTVel = {
            (tPos.x - s_prevTargetPos.x) / dt,
            (tPos.y - s_prevTargetPos.y) / dt,
            (tPos.z - s_prevTargetPos.z) / dt
        };
        // Отсекаем телепорты
        float len = std::sqrt(newTVel.x*newTVel.x + newTVel.y*newTVel.y + newTVel.z*newTVel.z);
        if (len > kMaxVel) {
            float k = kMaxVel / len;
            newTVel.x *= k; newTVel.y *= k; newTVel.z *= k;
        }
    }
    s_prevTargetPos = tPos;
    s_havePrevTarget = true;

    // ─── Скорость локального игрока ───────────────────────
    Vector3 newLVel = {0, 0, 0};
    if (s_havePrevLocal) {
        newLVel = {
            (lPos.x - s_prevLocalPos.x) / dt,
            (lPos.y - s_prevLocalPos.y) / dt,
            (lPos.z - s_prevLocalPos.z) / dt
        };
        float len = std::sqrt(newLVel.x*newLVel.x + newLVel.y*newLVel.y + newLVel.z*newLVel.z);
        if (len > kMaxVel) {
            float k = kMaxVel / len;
            newLVel.x *= k; newLVel.y *= k; newLVel.z *= k;
        }
    }
    s_prevLocalPos = lPos;
    s_havePrevLocal = true;

    {
        std::lock_guard<std::mutex> lk(g_lock);
        // EMA-сглаживание сохраняет старую скорость, подмешивая новую.
        g_tVel.x = g_tVel.x * (1.0f - kVelSmoothAlpha) + newTVel.x * kVelSmoothAlpha;
        g_tVel.y = g_tVel.y * (1.0f - kVelSmoothAlpha) + newTVel.y * kVelSmoothAlpha;
        g_tVel.z = g_tVel.z * (1.0f - kVelSmoothAlpha) + newTVel.z * kVelSmoothAlpha;

        g_lVel.x = g_lVel.x * (1.0f - kVelSmoothAlpha) + newLVel.x * kVelSmoothAlpha;
        g_lVel.y = g_lVel.y * (1.0f - kVelSmoothAlpha) + newLVel.y * kVelSmoothAlpha;
        g_lVel.z = g_lVel.z * (1.0f - kVelSmoothAlpha) + newLVel.z * kVelSmoothAlpha;

        // Небольшой up-bias, компенсирует гравитацию и вертикальный хитбокс
        g_tPos.x = tPos.x;
        g_tPos.y = tPos.y + 0.03f;
        g_tPos.z = tPos.z;

        g_lPos   = lPos;
        g_aimPtr = aimPtr;
    }
    g_hasData.store(true, std::memory_order_release);

    // ─── Мгновенный пинг, чтобы первый же выстрел застал свежие данные ───
    Vector3 predTarget = {
        g_tPos.x + g_tVel.x * kLeadSec,
        g_tPos.y + g_tVel.y * kLeadSec,
        g_tPos.z + g_tVel.z * kLeadSec
    };
    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    if (isZeroV3(origin)) origin = g_lPos;
    Vector3 diff = {
        predTarget.x - origin.x,
        predTarget.y - origin.y,
        predTarget.z - origin.z
    };
    float lenSq = diff.x*diff.x + diff.y*diff.y + diff.z*diff.z;
    if (lenSq > 0.0001f) {
        float inv = 1.0f / std::sqrt(lenSq);
        WriteAddr<Vector3>(aimPtr + kHit_RayDir,
                           Vector3{diff.x*inv, diff.y*inv, diff.z*inv});
    }
}
