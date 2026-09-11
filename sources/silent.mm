#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <cmath>
#include <atomic>
#include <chrono>
#include <thread>
#include <cstring>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;

// Смещение флага стрельбы или состояния оружия (нужно уточнить под конкретную версию, если отличается)
static constexpr uint64_t kWeapon_IsFiring      = 0x58; // Пример смещения флага огня

static constexpr float kHeadCenterY = 0.055f;
static constexpr uint64_t kTransitionCooldownMs = 500;

struct SharedData {
    uint64_t aimPtr;
    uint64_t weaponPtr; // Указатель на оружие для отслеживания момента выстрела
    float hx, hy, hz;
    float lx, ly, lz;
};

static std::atomic<bool>       g_started{false};
static std::atomic<uint64_t>   g_transitionTick{0};
static uint64_t                g_lastMatch = 0;

static std::atomic<SharedData> g_sharedData{};
static std::atomic<bool>       g_hasData{false};

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
//  WORKER — проверка выстрела и безопасная запись нормализованного вектора
// ═══════════════════════════════════════════════════════════════
static void SilentWorker() {
    while (true) {
        uint64_t tTick = g_transitionTick.load(std::memory_order_relaxed);
        if (tTick != 0 && (nowMs() - tTick) < kTransitionCooldownMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }

        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }

        SharedData data = g_sharedData.load(std::memory_order_relaxed);
        if (!validPtr(data.aimPtr)) {
            std::this_thread::yield();
            continue;
        }

        // Опционально: проверяем, идет ли процесс стрельбы, чтобы не портить каждый кадр
        // Если такого смещения нет, можно убрать эту проверку, но с ней надежнее
        if (validPtr(data.weaponPtr)) {
            bool isFiring = ReadAddr<bool>(data.weaponPtr + kWeapon_IsFiring);
            if (!isFiring) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
        }

        Vector3 origin = ReadAddr<Vector3>(data.aimPtr + kHit_StartPos);
        if (origin.x == 0.0f && origin.y == 0.0f && origin.z == 0.0f) {
            origin = {data.lx, data.ly, data.lz};
        }

        // Вычисляем разницу
        Vector3 diff = {
            data.hx - origin.x,
            data.hy - origin.y,
            data.hz - origin.z
        };

        // Нормализация вектора (предотвращает улет пуль назад из-за неверной длины)
        float length = std::sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z);
        if (length > 0.0001f) {
            diff.x /= length;
            diff.y /= length;
            diff.z /= length;
        }

        WriteAddr<Vector3>(data.aimPtr + kHit_RayDir, diff);
        
        // Небольшая задержка после записи, чтобы дать игре обработать кадр выстрела
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true)) {
        std::thread worker(SilentWorker);
        worker.detach();
    }
}

void ResetSilentAim() {
    g_hasData.store(false, std::memory_order_release);
    g_transitionTick.store(nowMs(), std::memory_order_release);
    g_lastMatch = 0;
    g_sharedData.store(SharedData{}, std::memory_order_release);
}

// ═══════════════════════════════════════════════════════════════
//  RunSilentAim — обновление данных из основного потока
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

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;

    if (!isVaildPtr(local) || !isVaildPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    // Получаем текущее оружие игрока (зависит от вашей структуры, если есть функция получения текущего оружия)
    // uint64_t currentWeapon = ReadAddr<uint64_t>(local + 0x...); 

    Vector3 head = HeadPos(target);
    if (isZeroV3(head)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    head.y += kHeadCenterY;
    Vector3 lPos = HeadPos(local);

    SharedData newData;
    newData.aimPtr = aimPtr;
    newData.weaponPtr = 0; // Замените на реальный указатель на оружие, если используется проверка выстрела
    newData.hx = head.x; newData.hy = head.y; newData.hz = head.z;
    newData.lx = lPos.x; newData.ly = lPos.y; newData.lz = lPos.z;

    g_sharedData.store(newData, std::memory_order_release);
    g_hasData.store(true, std::memory_order_release);
}
