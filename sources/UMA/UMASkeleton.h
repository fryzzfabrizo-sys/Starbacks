#pragma once

#import "../../esp/Core/GameLogic.h"
#import "../../esp/drawing_view/offset.h"
#include <array>
#include <cmath>
#include <unordered_map>

namespace UMAExternal {

struct BoneSet {
    std::array<uint64_t, 21> transforms{};
};

static inline bool valid(uint64_t value) {
    return value >= 0x100000000ULL && value <= 0x0000FFFFFFFFFFFFULL;
}

static inline uint64_t readUmaData(uint64_t player) {
    if (!valid(player)) return 0;
    uint64_t avatarManager = ReadAddr<uint64_t>(player + kUmaAvatarManagerOffset);
    if (!valid(avatarManager)) return 0;
    uint64_t avatar = ReadAddr<uint64_t>(avatarManager + kUmaAvatarOffset);
    if (!valid(avatar)) return 0;
    uint64_t data = ReadAddr<uint64_t>(avatar + kUmaDataOffsetAvatarBase);
    if (!valid(data)) return 0;
    uint64_t skeleton = ReadAddr<uint64_t>(data + kUmaSkeletonOffset);
    return valid(skeleton) ? data : 0;
}

static inline std::unordered_map<uint64_t, BoneSet>& cache() {
    static std::unordered_map<uint64_t, BoneSet> values;
    return values;
}

static inline void clearCache() {
    cache().clear();
}

static inline bool resolveBoneSet(uint64_t player, BoneSet *out) {
    if (!out || !valid(player)) return false;
    BoneSet resolved{};
    uint64_t data = readUmaData(player);
    if (!valid(data)) return false;
    uint64_t skeleton = ReadAddr<uint64_t>(data + kUmaSkeletonOffset);
    uint64_t list = valid(skeleton) ? ReadAddr<uint64_t>(skeleton + kUmaBoneListOffset) : 0;
    if (!valid(list)) return false;
    int32_t count = ReadAddr<int32_t>(list + kUmaListSizeOffset);
    uint64_t items = ReadAddr<uint64_t>(list + kUmaListItemsOffset);
    if (!valid(items) || count <= 0 || count > 128) return false;

    static constexpr std::array<int32_t, 21> hashes = {
        kUmaBoneHeadHash, kUmaBoneNeckHash, kUmaBoneSpineHash, kUmaBoneSpine1Hash,
        kUmaBoneHipsHash, kUmaBoneLeftClavHash, kUmaBoneLeftArmHash, kUmaBoneLeftForeArmHash,
        kUmaBoneLeftHandHash, kUmaBoneRightClavHash, kUmaBoneRightArmHash, kUmaBoneRightForeArmHash,
        kUmaBoneRightHandHash, kUmaBoneLeftLegUpperHash, kUmaBoneLeftLegHash, kUmaBoneLeftAnkleHash,
        kUmaBoneLeftToeHash, kUmaBoneRightLegUpperHash, kUmaBoneRightLegHash,
        kUmaBoneRightAnkleHash, kUmaBoneRightToeHash,
    };

    for (int32_t i = 0; i < count; i++) {
        uint64_t bone = ReadAddr<uint64_t>(items + kUmaArrayItemsOffset + (uint64_t)i * sizeof(uint64_t));
        if (!valid(bone)) continue;
        int32_t hash = ReadAddr<int32_t>(bone + kUmaBoneNameHashOffset);
        for (size_t j = 0; j < hashes.size(); j++) {
            if (hash != hashes[j]) continue;
            uint64_t transform = ReadAddr<uint64_t>(bone + kUmaBoneTransformOffset);
            if (valid(transform)) resolved.transforms[j] = transform;
            break;
        }
    }

    bool any = false;
    for (uint64_t transform : resolved.transforms) any = any || valid(transform);
    if (!any) return false;
    *out = resolved;
    return true;
}

static inline bool readPositions(uint64_t player, std::array<Vector3, 21> *out) {
    if (!out || !valid(player)) return false;
    auto &entries = cache();
    auto it = entries.find(player);
    if (it == entries.end()) {
        BoneSet resolved{};
        if (!resolveBoneSet(player, &resolved)) return false;
        if (entries.size() > 128) entries.clear();
        it = entries.emplace(player, resolved).first;
    }

    bool any = false;
    for (size_t i = 0; i < it->second.transforms.size(); i++) {
        uint64_t transform = it->second.transforms[i];
        if (!valid(transform)) continue;
        Vector3 value = getPositionExt(transform);
        if (!std::isfinite(value.x) || !std::isfinite(value.y) || !std::isfinite(value.z)) continue;
        (*out)[i] = value;
        any = true;
    }
    if (any) return true;

    entries.erase(it);
    return false;
}

}
