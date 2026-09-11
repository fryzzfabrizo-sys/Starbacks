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

static constexpr float kHeadCenterY = 0.055f;

// ── Параметры выбора цели ────────────────────────────────
static constexpr float kMaxTargetDist  = 200.0f;  // игнор дальше 200 м
static constexpr float kMaxScreenDist  = 1e9f;    // без FOV-ограничения для silent

// ── Защита от краша при смене матча ──────────────────────
static constexpr uint64_t kTransitionCooldownMs = 500;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static std::atomic<uint64_t> g_transitionTick{0};

static uint64_t g_aimPtr   = 0;
static Vector3  g_headPos  = {};
static Vector3  g_localPos = {};

static uint64_t g_lastMatch = 0;

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool isZeroV3(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}
static inline uint64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// ═══════════════════════════════════════════════════════════════
//  УЛУЧШЕННЫЙ ВЫБОР ЦЕЛИ (по референсам C#/C++)
//  Правила:
//    1. Только валидные указатели
//    2. Не тиммейт, не dead, не knocked
//    3. HP > 0
//    4. Дистанция ≤ kMaxTargetDist
//    5. Ближайший к центру экрана (если W2S доступен)
//    6. Fallback: ближайший по мировой дистанции
// ═══════════════════════════════════════════════════════════════
static uint64_t PickBestTarget(uint64_t match, uint64_t local, float *outDistSq) {
    uint64_t playerDict = ReadAddr<uint64_t>(match + kMatchPlayerDict);
    if (!isVaildPtr(playerDict)) return 0;

    uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
    if (!isVaildPtr(entriesArr)) return 0;

    int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
    if (slotCap <= 0 || slotCap > 256) return 0;

    Vector3 lPos = HeadPos(local);
    if (isZeroV3(lPos)) return 0;

    uint64_t bestTarget   = 0;
    float    bestScreenSq = kMaxScreenDist;
    float    bestDistSq   = FLT_MAX;

    const uint64_t base = entriesArr + kIl2CppArrayItems;

    for (int i = 0; i < slotCap; i++) {
        uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
        if (ReadAddr<int>(ent) == 0) continue;

        uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
        if (!isVaildPtr(pawn)) continue;
        if (pawn == local) continue;
        if (isLocalTeamMate(local, pawn)) continue;

        // HP > 0 — цель ещё жива
        if (get_CurHP(pawn) <= 0) continue;

        // Дистанция до цели
        Vector3 pPos = HeadPos(pawn);
        if (isZeroV3(pPos)) continue;
        float dSq = Vector3::DistanceSq(lPos, pPos);
        if (dSq > kMaxTargetDist * kMaxTargetDist) continue;

        // Экранная дистанция до центра (если возможно)
        float screenSq = kMaxScreenDist;
        float *matrix = GetViewMatrix(CameraMain(match));
        if (matrix) {
            Vector3 w2s = WorldToScreenLayer(pPos, matrix, (float)1080, (float)1920, (float)1080, (float)1920);
            if (w2s.z > 0.001f) {
                float dx = w2s.x - 540.0f;   // половина ширины
                float dy = w2s.y - 960.0f;   // половина высоты
                screenSq = dx * dx + dy * dy;
            }
        }

        // Приоритет: ближе к центру экрана, при равенстве — ближе по миру
        if (screenSq < bestScreenSq - 0.01f ||
            (std::fabs(screenSq - bestScreenSq) < 0.01f && dSq < bestDistSq)) {
            bestScreenSq = screenSq;
            bestDistSq   = dSq;
            bestTarget   = pawn;
        }
    }

    if (outDistSq) *outDistSq = bestDistSq;
    return bestTarget;
}

// ═══════════════════════════════════════════════════════════════
//  WORKER — yield, никаких sleep_for
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_acquire);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::yield();
            continue;
        }

        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        uint64_t h;
        Vector3 headPos, localPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h        = g_aimPtr;
            headPos  = g_headPos;
            localPos = g_localPos;
        }
        if (!validPtr(h)) {
            std::this_thread::yield();
            continue;
        }

        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        if (isZeroV3(origin)) origin = localPos;

        Vector3 dir = {
            headPos.x - origin.x,
            headPos.y - origin.y,
            headPos.z - origin.z
        };

        WriteAddr<Vector3>(h + kHit_RayDir, dir);

        std::this_thread::yield();
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_transitionTick.store(nowMs(), std::memory_order_release);
    g_lastMatch = 0;
    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = 0;
        g_headPos  = {};
        g_localPos = {};
    }
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — выбирает лучшую цель сам, не полагается на esp.mm
// ═══════════════════════════════════════════════════════════════
void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !isVaildPtr(cachedMatch)) {
        ResetSilentAim();
        return;
    }

    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        return;
    }

    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // ═══ УЛУЧШЕННЫЙ ВЫБОР ЦЕЛИ ═══
    // Приоритет нашему выбору. Fallback — g_SilentBestTarget из esp.mm.
    uint64_t target = PickBestTarget(cachedMatch, local, nullptr);
    if (!isVaildPtr(target)) {
        target = g_SilentBestTarget;
    }
    if (!isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 head = HeadPos(target);
    if (isZeroV3(head)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }
    head.y += kHeadCenterY;

    Vector3 lPos = HeadPos(local);

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr   = aimPtr;
        g_headPos  = head;
        g_localPos = lPos;
    }
    g_hasData.store(true, std::memory_order_release);

    // Мгновенный пинг
    {
        Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
        if (isZeroV3(origin)) origin = lPos;

        Vector3 dir = {
            head.x - origin.x,
            head.y - origin.y,
            head.z - origin.z
        };
        WriteAddr<Vector3>(aimPtr + kHit_RayDir, dir);
    }
}
