#import "no_recoil.h"
#import "../esp/Core/pid.h"
#import "../esp/drawing_view/offset.h"
#include <algorithm>
#include <atomic>
#include <cstring>
#include <mach/mach.h>
#include <mutex>
#include <thread>
#include <vector>

// No Recoil scan values are centralized in offset.h.
static std::mutex g_noRecoilLock;
static std::vector<mach_vm_address_t> g_noRecoilResults;
static std::atomic<bool> g_noRecoilEnabled{false};
static std::atomic<bool> g_noRecoilScanning{false};

static std::vector<mach_vm_address_t> ScanNoRecoilValues() {
    std::vector<mach_vm_address_t> results;
    mach_vm_address_t address = kNoRecoilScanStartAddress;
    task_t task = mach_task_self();

    while (address < kNoRecoilScanEndAddress) {
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

        mach_vm_address_t scanStart = std::max(regionAddress, kNoRecoilScanStartAddress);
        mach_vm_address_t scanEnd = std::min(next, kNoRecoilScanEndAddress);
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
                    if (value == kNoRecoilOriginalValue) results.push_back(chunkStart + i);
                }
            }
            chunkStart += chunkSize;
        }
    }
    return results;
}

void NoRecoilSetEnabled(bool enabled) {
    if (!enabled) {
        g_noRecoilEnabled.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> lock(g_noRecoilLock);
        uint32_t originalValue = kNoRecoilOriginalValue;
        for (mach_vm_address_t address : g_noRecoilResults)
            _write((long)address, &originalValue, sizeof(originalValue));
        g_noRecoilResults.clear();
        return;
    }

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
                uint32_t modified = kNoRecoilModifiedValue;
                for (mach_vm_address_t address : g_noRecoilResults) {
                    _write((long)address, &modified, sizeof(modified));
                }
            }
        }
        g_noRecoilScanning.store(false, std::memory_order_release);
    }).detach();
}

void NoRecoilReset(void) {
    NoRecoilSetEnabled(false);
}
