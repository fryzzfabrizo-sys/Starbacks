#ifndef STARBACKS_UMA_SKELETON_H
#define STARBACKS_UMA_SKELETON_H

#import "../esp/Core/UnityMath.h"

static constexpr uint64_t kUMAPlayerAvatarManager = 0x708;
static constexpr uint64_t kUMAAvatarManagerAvatar = 0x138;
static constexpr uint64_t kUMAAvatarUMAData = 0x28;
static constexpr uint64_t kUMADataSkeleton = 0x138;
static constexpr uint64_t kUMAGetBoneTransformRVA = 0x1A5BF34;
static constexpr uint64_t kUMATransformGetPositionRVA = 0x91CA5D0;

static inline bool UMAValidPtr(uint64_t value) {
    return value >= 0x100000000ULL && value <= 0x0000FFFFFFFFFFFFULL;
}

static inline int UMAHashName(const char *name) {
    uint32_t hash = 0;
    for (const unsigned char *p = (const unsigned char *)name; *p; ++p) {
        hash = hash * 31u + *p;
    }
    return (int)hash;
}

static inline uint64_t UMAGetSkeleton(uint64_t player) {
    if (!UMAValidPtr(player)) return 0;
    uint64_t avatarManager = ReadAddr<uint64_t>(player + kUMAPlayerAvatarManager);
    if (!UMAValidPtr(avatarManager)) return 0;
    uint64_t avatar = ReadAddr<uint64_t>(avatarManager + kUMAAvatarManagerAvatar);
    if (!UMAValidPtr(avatar)) return 0;
    uint64_t umaData = ReadAddr<uint64_t>(avatar + kUMAAvatarUMAData);
    if (!UMAValidPtr(umaData)) return 0;
    uint64_t skeleton = ReadAddr<uint64_t>(umaData + kUMADataSkeleton);
    return UMAValidPtr(skeleton) ? skeleton : 0;
}

static inline Vector3 UMABoneWorldPosition(uint64_t player, uint64_t moduleBase, const char *boneName) {
    if (!UMAValidPtr(moduleBase)) return {};
    uint64_t skeleton = UMAGetSkeleton(player);
    if (!UMAValidPtr(skeleton)) return {};

    using GetBoneTransform = uint64_t (*)(uint64_t, int);
    auto getBoneTransform = (GetBoneTransform)(moduleBase + kUMAGetBoneTransformRVA);
    uint64_t transform = getBoneTransform(skeleton, UMAHashName(boneName));
    if (!UMAValidPtr(transform)) return {};

    using GetPosition = void (*)(uint64_t, Vector3 *);
    auto getPosition = (GetPosition)(moduleBase + kUMATransformGetPositionRVA);
    Vector3 result{};
    getPosition(transform, &result);
    return result;
}

#endif
