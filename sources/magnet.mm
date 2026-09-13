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
extern bool     aimMagnet;      // добавить в esp.mm как другие bool-настройки

// Transform write offsets (из AimMagnet кода + наш project)
// headTrans → +0x10 → p3 → +0x38 → matPtr → write at +0x90
static constexpr uint64_t kT_Inner  = 0x10;
static constexpr uint64_t kT_Matrix = 0x38;
static constexpr uint64_t kT_PosOff = 0x90; // local position в матрице

// Магнит: насколько притягиваем (0=нет, 1=полностью на луч)
static constexpr float kMagnetStrength   = 0.4f;
static constexpr float kMagnetMaxDist    = 50.0f; // метры

static std::mutex        mag_lock;
static std::atomic<bool> mag_hasData{false};
static std::atomic<bool> mag_started{false};

static uint64_t mag_target   = 0;
static Vector3  mag_camPos   = {};
static Vector3  mag_camFwd   = {};
static Vector3  mag_origHead = {}; // оригинальная позиция для restore

static uint64_t mag_lastTarget = 0; // для restore предыдущей цели

static inline float dot(Vector3 a, Vector3 b) {
    return a.x*b.x + a.y*b.y + a.z*b.z;
}
static inline float vlen(Vector3 v) {
    return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
}

static Vector3 HeadPos(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {};
    uint64_t t = getHead(pawn);
    return isVaildPtr(t) ? getPositionExt(t) : Vector3{};
}

// Записываем позицию в transform врага
// chain: headTransNode → +0x10 → p3 → +0x38 → matPtr → +0x90
static bool WriteHeadPos(uint64_t pawn, Vector3 pos) {
    if (!isVaildPtr(pawn)) return false;
    uint64_t headNode = ReadAddr<uint64_t>(pawn + kHeadNode); // ITransformNode*
    if (!isVaildPtr(headNode)) return false;
    uint64_t transNode = ReadAddr<uint64_t>(headNode + kBodyPartTransNode); // +0x10
    if (!isVaildPtr(transNode)) return false;
    uint64_t p3 = ReadAddr<uint64_t>(transNode + kT_Inner); // +0x10
    if (!isVaildPtr(p3)) return false;
    uint64_t matPtr = ReadAddr<uint64_t>(p3 + kT_Matrix); // +0x38
    if (!isVaildPtr(matPtr)) return false;
    WriteAddr<Vector3>(matPtr + kT_PosOff, pos);
    WriteAddr<Vector3>(matPtr + kT_PosOff, pos); // двойная запись как в оригинале
    return true;
}

static void MagnetWorker() {
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(50));

        if (!mag_hasData.load(std::memory_order_acquire)) continue;

        uint64_t target;
        Vector3  camPos, camFwd;
        {
            std::lock_guard<std::mutex> lk(mag_lock);
            target = mag_target;
            camPos = mag_camPos;
            camFwd = mag_camFwd;
        }
        if (!isVaildPtr(target)) continue;

        Vector3 headPos = HeadPos(target);
        if (headPos.x == 0 && headPos.y == 0 && headPos.z == 0) continue;

        // Проверяем дистанцию
        Vector3 toEnemy = { headPos.x-camPos.x, headPos.y-camPos.y, headPos.z-camPos.z };
        float dist = vlen(toEnemy);
        if (dist > kMagnetMaxDist || dist < 0.5f) continue;

        // Проецируем на луч камеры
        float projDist = dot(toEnemy, camFwd);
        if (projDist < 0.5f) continue;

        // Точка на луче камеры на расстоянии dist
        Vector3 onRay = {
            camPos.x + camFwd.x * projDist,
            camPos.y + camFwd.y * projDist,
            camPos.z + camFwd.z * projDist
        };

        // Lerp между реальной позицией и точкой на луче
        Vector3 newPos = {
            headPos.x + (onRay.x - headPos.x) * kMagnetStrength,
            headPos.y + (onRay.y - headPos.y) * kMagnetStrength,
            headPos.z + (onRay.z - headPos.z) * kMagnetStrength
        };

        WriteHeadPos(target, newPos);
    }
}

void InitMagnetThread() {
    bool exp = false;
    if (mag_started.compare_exchange_strong(exp, true))
        std::thread(MagnetWorker).detach();
}

// Передаём камеру и цель из esp.mm каждый кадр
void RunAimMagnet(uint64_t target, Vector3 camPos, Vector3 camForward) {
    InitMagnetThread();

    if (!aimMagnet || !isVaildPtr(target)) {
        mag_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(mag_lock);
        mag_target = target;
        mag_camPos = camPos;
        mag_camFwd = camForward;
    }
    mag_hasData.store(true, std::memory_order_release);
}

void ResetAimMagnet() {
    mag_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(mag_lock);
    mag_target = 0;
}
