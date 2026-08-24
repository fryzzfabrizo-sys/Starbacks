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
extern bool aimsilent1;

static Vector3 GetHeadPosition(uint64_t pawn) {
    if (!isVaildPtr(pawn)) return {0.0f, 0.0f, 0.0f};
    uint64_t headTrans = getHead(pawn);
    if (!isVaildPtr(headTrans)) return {0.0f, 0.0f, 0.0f};
    return getPositionExt(headTrans);
}

static std::mutex g_silentLock;
static uint64_t g_silentPlayer = 0;
static Vector3 g_silentTarget = {0.0f, 0.0f, 0.0f};
static Vector3 g_silentLocal = {0.0f, 0.0f, 0.0f};
static std::atomic<bool> g_silentData{false};
static std::atomic<bool> g_silentThreadStarted{false};

static void SilentAimWorker() {
    const uint64_t hitObjectOffsets[] = {0xDC8, 0xDD0, 0xA90, 0xAA0};
    while (true) {
        std::this_thread::sleep_for(std::chrono::microseconds(3));
        if (!g_silentData.load(std::memory_order_acquire)) continue;

        uint64_t localPlayer;
        Vector3 targetPos;
        Vector3 localPos;
        {
            std::lock_guard<std::mutex> lock(g_silentLock);
            localPlayer = g_silentPlayer;
            targetPos = g_silentTarget;
            localPos = g_silentLocal;
        }

        if (!isVaildPtr(localPlayer)) continue;

        for (uint64_t offset : hitObjectOffsets) {
            uint64_t hitObjInfo = ReadAddr<uint64_t>(localPlayer + offset);
            if (!isVaildPtr(hitObjInfo)) continue;

            Vector3 base = ReadAddr<Vector3>(hitObjInfo + 0x4C);
            if (base.x == 0.0f && base.y == 0.0f && base.z == 0.0f) {
                base = localPos;
            }

            Vector3 direction = {
                targetPos.x - base.x,
                targetPos.y - base.y,
                targetPos.z - base.z
            };
            const float lengthSquared =
                direction.x * direction.x +
                direction.y * direction.y +
                direction.z * direction.z;
            if (lengthSquared <= 0.0001f) continue;

            const float inverseLength = 1.0f / std::sqrt(lengthSquared);
            direction.x *= inverseLength;
            direction.y *= inverseLength;
            direction.z *= inverseLength;

            WriteAddr<Vector3>(hitObjInfo + 0x40, direction);
            WriteAddr<Vector3>(hitObjInfo + 0x28, targetPos);
            WriteAddr<float>(hitObjInfo + 0x5C, 0.0f);
        }
    }
}

void InitSilentAimThread() {
    bool expected = false;
    if (g_silentThreadStarted.compare_exchange_strong(expected, true)) {
        std::thread(SilentAimWorker).detach();
    }
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || !isVaildPtr(cachedMatch)) {
        g_silentData.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lock(g_silentLock);
        g_silentPlayer = 0;
        return;
    }

    uint64_t localPlayer = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!isVaildPtr(localPlayer) || !isVaildPtr(target)) {
        g_silentData.store(false, std::memory_order_release);
        return;
    }

    Vector3 targetPos = GetHeadPosition(target);
    if (targetPos.x == 0.0f && targetPos.y == 0.0f && targetPos.z == 0.0f) {
        g_silentData.store(false, std::memory_order_release);
        return;
    }

    Vector3 localPos = GetHeadPosition(localPlayer);
    {
        std::lock_guard<std::mutex> lock(g_silentLock);
        g_silentPlayer = localPlayer;
        g_silentTarget = targetPos;
        g_silentLocal = localPos;
    }
    g_silentData.store(true, std::memory_order_release);
}
