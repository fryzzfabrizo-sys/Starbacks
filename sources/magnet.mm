// magnet.mm
// Aim Magnet через root transform (0x660).
// Работает только в ADS.
//   • Y НЕ меняется — фиксируется на исходной позиции врага
//   • голова тянется ровно в центр прицела (X/Z)
//   • anti-jitter: deadzone + запоминание последней записанной позиции
//   • clamp: не тянуть врага дальше kMagMaxDisplacement от исходной позиции

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/offset.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimMagnet;

extern bool get_IsScoping(uint64_t p);

// ─── root transform offset ──────────────────────────────
static constexpr uint64_t kMag_RootNode = 0x660;
static constexpr uint64_t kMag_BodyPart = 0x10;
static constexpr uint64_t kMag_Inner    = 0x10;
static constexpr uint64_t kMag_Matrix   = 0x38;
static constexpr uint64_t kMag_PosOff   = 0x90;

// ─── Параметры магнита ──────────────────────────────────
static constexpr float kMagStrength   = 0.55f;   // скорость притяжения (было 0.35)
static constexpr float kMagHeadOffset = 1.5f;    // (уже не нужно — Y фиксируем, но оставим)
static constexpr float kMagMaxDist    = 80.0f;
static constexpr float kMagMinDist    = 1.0f;

// Максимальное смещение врага от исходной позиции (метры)
static constexpr float kMagMaxDisplacement = 1.2f;

// Угол "враг в прицеле" (град)
static constexpr float kMagMaxAngleDeg     = 12.0f;

// Мёртвая зона по XZ — если смещение < этого значения, не двигаем (анти-дрожание)
static constexpr float kMagDeadZone        = 0.03f;

// Порог "почти совпало" — считаем, что модель встала, и не пишем новые значения
static constexpr float kMagSnapEps         = 0.005f;

static constexpr int   kMagTickMs     = 4;
static constexpr int   kMagReleaseMs  = 200;

static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_candidate = 0;
static Vector3  mag_camPos    = {};
static Vector3  mag_camFwd    = {};
static uint64_t mag_locked    = 0;

// Исходная позиция root врага — фиксируется при захвате цели.
// Y берём строго отсюда, X/Z не даём уходить дальше kMagMaxDisplacement.
static Vector3  mag_originalRoot = {};
static bool     mag_originalRootValid = false;

// Последняя записанная позиция (анти-дрожание)
static Vector3  mag_lastWritten = {};
static bool     mag_lastWrittenValid = false;

static std::chrono::steady_clock::time_point mag_lastUpdate =
    std::chrono::steady_clock::now();

static inline float vlen3(Vector3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static inline float vlen2xz(Vector3 v) { return sqrtf(v.x*v.x + v.z*v.z); }
static inline bool  isZero3(Vector3 v) { return v.x==0.f && v.y==0.f && v.z==0.f; }
static inline bool  isSane3(Vector3 v) {
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return false;
    if (fabsf(v.x) > 20000.f || fabsf(v.y) > 20000.f || fabsf(v.z) > 20000.f) return false;
    return true;
}

static Vector3 HeadWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

static Vector3 RootWorld(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t node = ReadAddr<uint64_t>(pawn + kMag_RootNode);
    if (!isVaildPtr(node)) return {};
    uint64_t tf = ReadAddr<uint64_t>(node + kMag_BodyPart);
    if (!isVaildPtr(tf)) return {};
    return getPositionExt(tf);
}

static uint64_t MatPtr(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return 0;
    uint64_t node = ReadAddr<uint64_t>(pawn + kMag_RootNode);
    if (!isVaildPtr(node)) return 0;
    uint64_t tf = ReadAddr<uint64_t>(node + kMag_BodyPart);
    if (!isVaildPtr(tf)) return 0;
    uint64_t p3 = ReadAddr<uint64_t>(tf + kMag_Inner);
    if (!isVaildPtr(p3)) return 0;
    uint64_t mat = ReadAddr<uint64_t>(p3 + kMag_Matrix);
    return isVaildPtr(mat) ? mat : 0;
}

static bool WriteLocalRoot(uint64_t pawn, Vector3 pos) {
    if (!isSane3(pos)) return false;
    uint64_t mat = MatPtr(pawn);
    if (!isVaildPtr(mat)) return false;
    WriteAddr<Vector3>(mat + kMag_PosOff, pos);
    return true;
}

// Враг в пределах kMagMaxAngleDeg от прицела
static bool IsInCrosshair(const Vector3& camPos, const Vector3& camFwd, const Vector3& enemyHead) {
    Vector3 toEnemy = { enemyHead.x - camPos.x,
                        enemyHead.y - camPos.y,
                        enemyHead.z - camPos.z };
    float len = vlen3(toEnemy);
    if (len < 0.001f) return false;

    float inv = 1.0f / len;
    float dot = (toEnemy.x * camFwd.x + toEnemy.y * camFwd.y + toEnemy.z * camFwd.z) * inv;
    if (dot < -1.0f) dot = -1.0f;
    if (dot >  1.0f) dot =  1.0f;

    float angleDeg = acosf(dot) * 180.0f / 3.14159265f;
    return angleDeg <= kMagMaxAngleDeg;
}

// Точка на луче прицела, лежащая на высоте enemyHead.y.
// Если луч почти горизонтальный (camFwd.y ≈ 0), используем расстояние до врага.
static Vector3 PointOnRayAtHeadHeight(const Vector3& camPos, const Vector3& camFwd, float headY) {
    float t;
    if (fabsf(camFwd.y) < 0.001f) {
        // Луч горизонтальный — берём фиксированную дистанцию
        t = 20.0f;
    } else {
        t = (headY - camPos.y) / camFwd.y;
        if (t < 0.1f) t = 0.1f;
        if (t > kMagMaxDist) t = kMagMaxDist;
    }
    return {
        camPos.x + camFwd.x * t,
        headY,                        // гарантируем — Y ровно на высоте головы
        camPos.z + camFwd.z * t
    };
}

static bool ApplyMagnet(uint64_t pawn, const Vector3& camPos, const Vector3& camFwd) {
    Vector3 headW = HeadWorld(pawn);
    if (!isSane3(headW) || isZero3(headW)) return false;

    if (!IsInCrosshair(camPos, camFwd, headW)) return false;

    float dist = vlen3({headW.x - camPos.x, headW.y - camPos.y, headW.z - camPos.z});
    if (dist < kMagMinDist || dist > kMagMaxDist) return false;

    Vector3 curRootW = RootWorld(pawn);
    if (!isSane3(curRootW) || isZero3(curRootW)) return false;

    if (!mag_originalRootValid) return false;

    // ── Целевая точка по X/Z — пересечение прицела с плоскостью головы ──
    Vector3 rayPt = PointOnRayAtHeadHeight(camPos, camFwd, headW.y);

    // Хотим, чтобы ГОЛОВА оказалась на линии прицела.
    // Root должен сдвинуться на ту же дельту по XZ, что и голова.
    Vector3 headDeltaXZ = { rayPt.x - headW.x, 0.0f, rayPt.z - headW.z };

    // Текущий root + дельта (Y НЕ трогаем — остаётся как в исходной позиции)
    Vector3 targetRoot = {
        curRootW.x + headDeltaXZ.x,
        mag_originalRoot.y,        // Y жёстко фиксирован
        curRootW.z + headDeltaXZ.z
    };

    // Плавно тянем по XZ
    Vector3 lerped = {
        curRootW.x + (targetRoot.x - curRootW.x) * kMagStrength,
        mag_originalRoot.y,
        curRootW.z + (targetRoot.z - curRootW.z) * kMagStrength
    };

    // ── Кламп по максимальному смещению от исходной позиции (по XZ) ──
    Vector3 deltaOrig = { lerped.x - mag_originalRoot.x, 0.0f, lerped.z - mag_originalRoot.z };
    float dOrig = vlen2xz(deltaOrig);
    if (dOrig > kMagMaxDisplacement && dOrig > 0.0001f) {
        float s = kMagMaxDisplacement / dOrig;
        lerped.x = mag_originalRoot.x + deltaOrig.x * s;
        lerped.z = mag_originalRoot.z + deltaOrig.z * s;
    }

    // ── Анти-дрожание ──
    // 1) мёртвая зона — если цель уже почти достигнута, не двигаем
    Vector3 toTargetXZ = { targetRoot.x - curRootW.x, 0.0f, targetRoot.z - curRootW.z };
    if (vlen2xz(toTargetXZ) < kMagDeadZone) {
        // Ничего не пишем — модель стоит на месте
        return false;
    }

    // 2) если новая позиция почти совпадает с последней записанной — тоже не пишем
    if (mag_lastWrittenValid) {
        Vector3 dLast = { lerped.x - mag_lastWritten.x, 0.0f, lerped.z - mag_lastWritten.z };
        if (vlen2xz(dLast) < kMagSnapEps) {
            return false;
        }
    }

    bool ok = WriteLocalRoot(pawn, lerped);
    if (ok) {
        mag_lastWritten = lerped;
        mag_lastWrittenValid = true;
    }
    return ok;
}

// Двойная страховка ADS
static bool IsLocalPlayerScoping(void) {
    if (!isVaildPtr(cachedMatch)) return false;
    uint64_t local = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(local)) return false;
    return get_IsScoping(local);
}

static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kMagTickMs));

        auto now = std::chrono::steady_clock::now();
        auto since = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now - mag_lastUpdate).count();
        if (since > kMagReleaseMs) {
            mag_locked = 0;
            mag_originalRootValid = false;
            mag_lastWrittenValid = false;
            continue;
        }

        if (!mag_hasData.load(std::memory_order_acquire)) {
            mag_locked = 0;
            mag_originalRootValid = false;
            mag_lastWrittenValid = false;
            continue;
        }

        uint64_t candidate;
        Vector3  camPos, camFwd;
        {
            std::lock_guard<std::mutex> lk(mag_lock);
            candidate = mag_candidate;
            camPos    = mag_camPos;
            camFwd    = mag_camFwd;
        }

        // Захват новой цели
        if (!isVaildPtr(mag_locked)) {
            if (isVaildPtr(candidate) && get_CurHP(candidate) > 0) {
                mag_locked = candidate;
                mag_originalRoot = RootWorld(candidate);
                mag_originalRootValid = isSane3(mag_originalRoot) && !isZero3(mag_originalRoot);
                mag_lastWrittenValid = false;
            }
            if (!isVaildPtr(mag_locked)) continue;
        }

        // Смена цели / смерть — сброс
        if (candidate != mag_locked || get_CurHP(mag_locked) <= 0) {
            mag_locked = 0;
            mag_originalRootValid = false;
            mag_lastWrittenValid = false;
            continue;
        }

        ApplyMagnet(mag_locked, camPos, camFwd);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward, bool enabled) {
    InitMagnetThread();

    if (!aimMagnet || !enabled || !isVaildPtr(target)) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    if (!IsLocalPlayerScoping()) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_candidate = target;
        mag_camPos    = camPos;
        mag_camFwd    = camForward;
    }
    mag_lastUpdate = std::chrono::steady_clock::now();
    mag_hasData.store(true, std::memory_order_release);
}

void ResetAimMagnet() {
    mag_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(mag_lock);
    mag_candidate = 0;
    mag_camPos    = {};
    mag_camFwd    = {};
    mag_locked    = 0;
    mag_originalRoot = {};
    mag_originalRootValid = false;
    mag_lastWritten = {};
    mag_lastWrittenValid = false;
}
