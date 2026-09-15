#pragma once

#import "../../esp/Core/GameLogic.h"
#import "../../esp/drawing_view/offset.h"
#include <cmath>

namespace UMAExternal {

// Bone hashes and memory offsets are centralized in offset.h.

static inline bool valid(uint64_t value) {
    return value >= 0x100000000ULL && value <= 0x0000FFFFFFFFFFFFULL;
}

static inline uint64_t readUmaData(uint64_t avatarManager) {
    if (!valid(avatarManager)) return 0;
    uint64_t avatar = ReadAddr<uint64_t>(avatarManager + kUmaAvatarOffset);
    if (!valid(avatar)) return 0;
    uint64_t data = ReadAddr<uint64_t>(avatar + kUmaDataOffsetAvatarBase);
    if (!valid(data)) return 0;
    uint64_t skeleton = ReadAddr<uint64_t>(data + kUmaSkeletonOffset);
    return valid(skeleton) ? data : 0;
}

static inline uint64_t findBoneTransform(uint64_t player, int32_t hash) {
    if (!valid(player)) return 0;
    uint64_t avatarManager = ReadAddr<uint64_t>(player + kUmaAvatarManagerOffset);
    uint64_t umaData = readUmaData(avatarManager);
    if (!valid(umaData)) return 0;
    uint64_t skeleton = ReadAddr<uint64_t>(umaData + kUmaSkeletonOffset);
    if (!valid(skeleton)) return 0;

    uint64_t list = ReadAddr<uint64_t>(skeleton + kUmaBoneListOffset);
    if (valid(list)) {
        int32_t count = ReadAddr<int32_t>(list + kUmaListSizeOffset);
        uint64_t items = ReadAddr<uint64_t>(list + kUmaListItemsOffset);
        if (valid(items) && count > 0 && count <= 128) {
            for (int32_t i = 0; i < count; i++) {
                uint64_t bone = ReadAddr<uint64_t>(items + kUmaArrayItemsOffset + (uint64_t)i * sizeof(uint64_t));
                if (!valid(bone)) continue;
                if (ReadAddr<int32_t>(bone + kUmaBoneNameHashOffset) != hash) continue;
                uint64_t transform = ReadAddr<uint64_t>(bone + kUmaBoneTransformOffset);
                if (valid(transform)) return transform;
            }
        }
    }

    uint64_t dictionary = ReadAddr<uint64_t>(skeleton + kUmaBoneDictionaryOffset);
    if (!valid(dictionary)) return 0;
    uint64_t entries = ReadAddr<uint64_t>(dictionary + kUmaDictionaryEntriesOffset);
    int32_t entryCount = ReadAddr<int32_t>(dictionary + kUmaDictionaryCountOffset);
    if (!valid(entries) || entryCount <= 0 || entryCount > 128) return 0;
    for (int32_t i = 0; i < entryCount; i++) {
        uint64_t entry = entries + kUmaArrayItemsOffset + (uint64_t)i * kUmaDictionaryEntryStride;
        if (ReadAddr<int32_t>(entry) != hash) continue;
        uint64_t bone = ReadAddr<uint64_t>(entry + kUmaDictionaryEntryValueOffset);
        if (!valid(bone)) return 0;
        uint64_t transform = ReadAddr<uint64_t>(bone + kUmaBoneTransformOffset);
        return valid(transform) ? transform : 0;
    }
    return 0;
}

static inline bool position(uint64_t player, int32_t hash, Vector3 *out) {
    if (!out) return false;
    uint64_t transform = findBoneTransform(player, hash);
    if (!valid(transform)) return false;
    Vector3 value = getPositionExt(transform);
    if (!std::isfinite(value.x) || !std::isfinite(value.y) || !std::isfinite(value.z)) return false;
    *out = value;
    return true;
}

}
