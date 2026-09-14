#pragma once

#import "../../esp/Core/GameLogic.h"
#include <cmath>

namespace UMAExternal {

static constexpr uint64_t kAvatarManager = 0x708;
static constexpr uint64_t kAvatar = 0x138;
static constexpr uint64_t kUmaData = 0x30;
static constexpr uint64_t kSkeleton = 0x138;
static constexpr uint64_t kBoneHashDataBackup = 0x20;
static constexpr uint64_t kListItems = 0x10;
static constexpr uint64_t kListSize = 0x18;
static constexpr uint64_t kArrayItems = 0x20;
static constexpr uint64_t kBoneNameHash = 0x10;
static constexpr uint64_t kBoneTransform = 0x18;

static constexpr int32_t Head = -2111735698;
static constexpr int32_t Neck = 96688289;
static constexpr int32_t Hips = 1529948125;
static constexpr int32_t Spine = -1051086991;
static constexpr int32_t Spine1 = -1541408846;
static constexpr int32_t LeftArm = 1604555488;
static constexpr int32_t LeftForeArm = -1129867206;
static constexpr int32_t LeftHand = 1892485702;
static constexpr int32_t RightArm = -1391784435;
static constexpr int32_t RightForeArm = 1507255706;
static constexpr int32_t RightHand = -1367065569;
static constexpr int32_t LeftLegUpper = -285661123;
static constexpr int32_t LeftLeg = -1305646021;
static constexpr int32_t LeftAnkle = -344692431;
static constexpr int32_t LeftToe = -1258743979;
static constexpr int32_t RightLegUpper = 952826536;
static constexpr int32_t RightLeg = 1082519766;
static constexpr int32_t RightAnkle = -115488425;
static constexpr int32_t RightToe = 1179749304;

static inline bool valid(uint64_t value) {
    return value >= 0x100000000ULL && value <= 0x0000FFFFFFFFFFFFULL;
}

static inline uint64_t readUmaData(uint64_t avatarManager) {
    if (!valid(avatarManager)) return 0;
    uint64_t direct = ReadAddr<uint64_t>(avatarManager + kUmaData);
    if (valid(direct)) return direct;
    uint64_t avatar = ReadAddr<uint64_t>(avatarManager + kAvatar);
    if (!valid(avatar)) return 0;
    return ReadAddr<uint64_t>(avatar + kUmaData);
}

static inline uint64_t findBoneTransform(uint64_t player, int32_t hash) {
    if (!valid(player)) return 0;
    uint64_t avatarManager = ReadAddr<uint64_t>(player + kAvatarManager);
    uint64_t umaData = readUmaData(avatarManager);
    if (!valid(umaData)) return 0;
    uint64_t skeleton = ReadAddr<uint64_t>(umaData + kSkeleton);
    if (!valid(skeleton)) return 0;
    uint64_t list = ReadAddr<uint64_t>(skeleton + kBoneHashDataBackup);
    if (!valid(list)) return 0;
    int32_t count = ReadAddr<int32_t>(list + kListSize);
    uint64_t items = ReadAddr<uint64_t>(list + kListItems);
    if (!valid(items) || count <= 0 || count > 128) return 0;
    uint64_t array = items;
    if (!valid(array)) return 0;
    for (int32_t i = 0; i < count; i++) {
        uint64_t bone = ReadAddr<uint64_t>(array + kArrayItems + (uint64_t)i * sizeof(uint64_t));
        if (!valid(bone)) continue;
        if (ReadAddr<int32_t>(bone + kBoneNameHash) != hash) continue;
        uint64_t transform = ReadAddr<uint64_t>(bone + kBoneTransform);
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
