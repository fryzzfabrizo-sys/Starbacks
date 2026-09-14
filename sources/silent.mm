// silent.mm
// Silent aim через ITransformNode головы (0x638)

#import "../esp/Core/GameLogic.h"
#import "../esp/drawing_view/esp.h"
#import "mahoa.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <cmath>
#include <algorithm>
#include <vector>
#include <cstring>
#include <mach/mach.h>

extern uint64_t Moudule_Base;
extern uint64_t g_SilentBestTarget;
extern uint64_t cachedMatch;
extern bool     aimsilent1;

static constexpr uint64_t kPlayer_LastAimInfo = 0xDC8;
static constexpr uint64_t kHit_RayDir         = 0x40;
static constexpr uint64_t kHit_StartPos       = 0x4C;
static constexpr uint64_t kHit_Scatter        = 0x5C;
static constexpr uint64_t kPlayer_HeadNode    = 0x638;
static constexpr uint64_t kBodyPart_TransNode = 0x10;

static std::mutex        g_lock;
static std::atomic<bool> g_hasData{false};
static std::atomic<bool> g_started{false};
static uint64_t          g_aimPtr    = 0;
static Vector3           g_tPos      = {};
static uint64_t          g_lastMatch = 0;

static constexpr uint32_t kNoRecoilOriginal = 1016018816U;
static constexpr uint32_t kNoRecoilModified = 180U;
static constexpr mach_vm_address_t kNoRecoilScanStart = 0x100000000ULL;
static constexpr mach_vm_address_t kNoRecoilScanEnd = 0x160000000ULL;
static std::mutex g_noRecoilLock;
static std::vector<mach_vm_address_t> g_noRecoilResults;
static std::atomic<bool> g_noRecoilEnabled{false};
static std::atomic<bool> g_noRecoilScanning{false};

static std::vector<mach_vm_address_t> ScanNoRecoilValues() {
    std::vector<mach_vm_address_t> results;
    mach_vm_address_t address = kNoRecoilScanStart;
    task_t task = mach_task_self();

    while (address < kNoRecoilScanEnd) {
        mach_vm_address_t regionAddress = address;
        mach_vm_size_t regionSize = 0;
        uint32_t depth = 0;
        vm_region_submap_info_data_64_t info{};
        mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = mach_vm_region_recurse(task, &regionAddress, &regionSize, &depth,
                                                   reinterpret_cast<vm_region_recurse_info_t>(&info),
                                                   &infoCount);
        if (kr != KERN_SUCCESS || regionSize == 0) break;
        mach_vm_address_t next = regionAddress + regionSize;
        if (next <= address) break;
        address = next;
        if (info.is_submap || !(info.protection & VM_PROT_READ) || !(info.protection & VM_PROT_WRITE)) continue;

        mach_vm_address_t scanStart = std::max(regionAddress, kNoRecoilScanStart);
        mach_vm_address_t scanEnd = std::min(next, kNoRecoilScanEnd);
        for (mach_vm_address_t chunkStart = scanStart; chunkStart < scanEnd;) {
            mach_vm_size_t chunkSize = (mach_vm_size_t)std::min<mach_vm_address_t>(0x100000ULL, scanEnd - chunkStart);
            std::vector<uint8_t> bytes((size_t)chunkSize);
            mach_vm_size_t outSize = 0;
            if (mach_vm_read_overwrite(task, chunkStart, chunkSize,
                                       reinterpret_cast<mach_vm_address_t>(bytes.data()), &outSize) == KERN_SUCCESS) {
                size_t limit = (size_t)outSize & ~((size_t)3);
                for (size_t i = 0; i + sizeof(uint32_t) <= limit; i += sizeof(uint32_t)) {
                    uint32_t value = 0;
                    std::memcpy(&value, bytes.data() + i, sizeof(value));
                    if (value == kNoRecoilOriginal) results.push_back(chunkStart + i);
                }
            }
            chunkStart += chunkSize;
        }
    }
    return results;
}

static void DisableNoRecoil() {
    g_noRecoilEnabled.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lock(g_noRecoilLock);
    for (mach_vm_address_t address : g_noRecoilResults) {
        _write((long)address, &kNoRecoilOriginal, sizeof(kNoRecoilOriginal));
    }
    g_noRecoilResults.clear();
}

static void EnableNoRecoil() {
    bool expected = false;
    if (!g_noRecoilEnabled.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return;
    bool scanExpected = false;
    if (!g_noRecoilScanning.compare_exchange_strong(scanExpected, true, std::memory_order_acq_rel)) {
        g_noRecoilEnabled.store(false, std::memory_order_release);
        return;
    }

    std::thread([] {
        std::vector<mach_vm_address_t> results = ScanNoRecoilValues();
        {
            std::lock_guard<std::mutex> lock(g_noRecoilLock);
            if (g_noRecoilEnabled.load(std::memory_order_acquire)) {
                g_noRecoilResults = results;
                for (mach_vm_address_t address : g_noRecoilResults) {
                    _write((long)address, &kNoRecoilModified, sizeof(kNoRecoilModified));
                }
            }
        }
        g_noRecoilScanning.store(false, std::memory_order_release);
    }).detach();
}

static inline bool validPtr(uint64_t p) {
    return p >= 0x100000000ULL && p <= 0x0000FFFFFFFFFFFFULL;
}
static inline bool validVec(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z) &&
           !(v.x == 0.f && v.y == 0.f && v.z == 0.f);
}
static Vector3 HeadPos(uint64_t pawn) {
    if (!validPtr(pawn)) return {};
    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + kPlayer_HeadNode);
    if (!validPtr(bodyPart)) return {};
    uint64_t node = ReadAddr<uint64_t>(bodyPart + kBodyPart_TransNode);
    if (!validPtr(node)) return {};
    return getPositionExt(node);
}

static void SilentWorker() {
    while (true) {
        if (!g_hasData.load(std::memory_order_acquire)) {
            std::this_thread::yield();
            continue;
        }
        uint64_t h;
        Vector3  tPos;
        {
            std::lock_guard<std::mutex> lk(g_lock);
            h    = g_aimPtr;
            tPos = g_tPos;
        }
        if (!validPtr(h) || !validVec(tPos)) {
            std::this_thread::yield();
            continue;
        }
        Vector3 origin = ReadAddr<Vector3>(h + kHit_StartPos);
        Vector3 diff   = { tPos.x - origin.x,
                           tPos.y - origin.y,
                           tPos.z - origin.z };
        float lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
        if (lenSq <= 0.0001f) {
            std::this_thread::yield();
            continue;
        }
        float invLen = 1.0f / std::sqrt(lenSq);
        Vector3 direction = { diff.x * invLen, diff.y * invLen, diff.z * invLen };
        WriteAddr<Vector3>(h + kHit_RayDir, direction);
        WriteAddr<float>(h + kHit_Scatter, 0.0f);
    }
}

void InitSilentAimThread() {
    bool exp = false;
    if (g_started.compare_exchange_strong(exp, true))
        std::thread(SilentWorker).detach();
}

void ResetSilentAim() {
    DisableNoRecoil();
    g_hasData.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(g_lock);
    g_aimPtr = 0;
    g_tPos   = {};
}

void RunSilentAim() {
    InitSilentAimThread();

    if (!aimsilent1 || IsAtLobby(Moudule_Base) || !validPtr(cachedMatch)) {
        g_lastMatch = 0;
        ResetSilentAim();
        return;
    }
    if (cachedMatch != g_lastMatch) {
        ResetSilentAim();
        g_lastMatch = cachedMatch;
        return;
    }
    EnableNoRecoil();

    uint64_t local  = getLocalPlayer(cachedMatch);
    uint64_t target = g_SilentBestTarget;
    if (!validPtr(local) || !validPtr(target)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    uint64_t aimPtr = ReadAddr<uint64_t>(local + kPlayer_LastAimInfo);
    if (!validPtr(aimPtr)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    Vector3 tPos = HeadPos(target);
    if (!validVec(tPos)) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_lock);
        g_aimPtr = aimPtr;
        g_tPos   = tPos;
    }
    g_hasData.store(true, std::memory_order_release);

    Vector3 origin = ReadAddr<Vector3>(aimPtr + kHit_StartPos);
    Vector3 diff   = { tPos.x - origin.x,
                       tPos.y - origin.y,
                       tPos.z - origin.z };
    float lenSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
    if (lenSq <= 0.0001f) {
        g_hasData.store(false, std::memory_order_release);
        return;
    }
    float invLen = 1.0f / std::sqrt(lenSq);
    Vector3 direction = { diff.x * invLen, diff.y * invLen, diff.z * invLen };
    WriteAddr<Vector3>(aimPtr + kHit_RayDir, direction);
    WriteAddr<float>(aimPtr + kHit_Scatter, 0.0f);
}
