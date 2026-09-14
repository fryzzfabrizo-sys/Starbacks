#pragma once

#define kGameFacadeTypeInfo      0xBFD8978
#define kTypeInfoStatics         0xB8
#define kCurrentGame             0x0
#define kCurrentMatchGame        0x8
#define kMatch                   0x90
#define kMatchLocalPlayer        0xD8
#define kCameraControllerManager 0xD8

#define kMainCamera              0x20
#define kCameraInner            0x10

#define kViewMatrixOff          0x80
#define kProjMatrixOff          0xC0
#define kBodyPartTransNode       0x10
#define kHeadNode               0x638  // ITransformNode Head
#define kHipNode                0x640  // ITransformNode Hip
#define kLeftAnkleNode           0x670
#define kRightAnkleNode          0x678
#define kRightToeNode            0x688
#define kLeftToeNode             0x680
#define kLeftShoulderNode        0x658
#define kRightShoulderNode       0x660
#define kLeftHandNode            0x6B8
#define kRightHandNode           0x6B0
#define kLeftElbowNode           0x6C8
#define kRightElbowNode          0x6C0
#define kPlayerIDStruct         0x2D0
#define kPlayerID               0x3A0
#define kUserID                 0x3A0
#define kIsClientBot            0x438  // confirmed
#define kDataPool               0x70
#define kDataPoolInner          0x10
#define kDataPoolEntriesBase    0x20
#define kDataPoolEntryStride    0x8
#define kDataPoolValue          0x18
#define kAimRotation            0x5AC
#define kAimRotationAux         0x5BC
#define kIsFiring               0x770  // DataPool entry index (used via get_IsFiring)

#define _0x27276BC 0x708// protected AvatarManager m_AvatarManager; // 0x620 protected AvatarManager FOGJNGDMJKJ; // 0x710

#define _0x28726BD 0x138// internal IUmaAvatar m_Avatar; // 0x118 internal IUmaAvatar EEAGBKBMBLD; // 0x128

#define _0x2872DCF 0x101// private bool IsVisible; // 0x101


#define kMainCameraTransform    0x380
#define kMyPhysXData            0x1B80
#define kPhxNpeononogeo         0x20
#define kGhgState               0x10
#define kKnocked                 0x1150
#define kKnockedDownBleeding     0x11A0
#define kKnockedDownBleedingGS   0x11A1
#define kMatchPlayerDict        0x148
#define kDictEntries            0x18
#define kDictCount              0x20
#define kIl2CppArrayMaxLength   0x18
#define kIl2CppArrayItems       0x20
#define kDictEntryStrideBytePlayer   24
#define kDictEntryValueOffByte       16
#define kTransformInner         0x10
#define kTransformMatrix        0x38
#define kTransformIndex         0x40
#define kMatrixList             0x18
#define kMatrixIndices          0x20
#define kNickname               0x430  // confirmed
#define kStringFirstChar        0x14
// ─── Weapon ───────────────────────────────────
#define _0x5BC2862 0x6D8 // protected OMELKCOGCBK LPEALCPGJBL; // 0x6D8

#define _0x2862BCD 0xA0//private NAELPAAELNO CHAFOMFBKEG; // 0xA0

#define kWeaponCostAmmo         0x7B8   // protected bool m_CostAmmo
#define kPlayerAttributes       0x700   // protected PlayerAttributes
#define kReloadNoConsumeAmmoclip 0xD8  // OB54dump.cs: PlayerAttributes.ReloadNoConsumeAmmoclip
#define kShootNoReload          0xD9    // public bool ShootNoReload
#define kFollowCamera            0x628   // LocalPlayer -> FollowCamera
#define kFOVOffset               0x70 
// Velocity prediction (OB54)
#define kPhysCCT          0x200   // PhysicalCCT pointer on Player
#define kPhysCCT_Velocity 0x17C   // Vector3 Velocity in PhysicalCCT

// Bone nodes OB54 (OB53 - 8)
#define kChestNode        0x648   // ITransformNode Breast/Chest
#define kNeckNode         0x640   // hip/neck position

// Silent aim check
#define kSAim1            0x7D8   // IFCJGLEOGDD bool (IsPrepareAttack, same OB53/OB54)

// Из Offsets.json (@THE_LION_CHEATS) — OB54 подтверждено
#define kLockAimCollider        0x140  // LockAimCollider_Backing (для silent aim HitCollider)
#define kAimCollider_Ptr        0x6C8  // AimCollider_Ptr (aim collider на Player)
#define kFollowCamera_Ptr       0x620  // FollowCamera_Ptr
#define kIsFire_Backing         0x7D0  // IsFire_Backing (JSON: 0x7D0)
#define kLastAimInfo_Alt        0xDC4  // LastAimInfo_Ptr Android ref (iOS = 0xDC8)
#define kIsVisible_Uma          0x100  // IsVisible offset в umaData
#define kUmaData                0x30   // umaData offset внутри AvatarManager

// Из Hooks.h: float PGCPFOAJHBM — разброс пули в GMPGMPFNMFP
#define kHit_RayDirectionOffset 0x40 // Hooks.h: HitInfo.direction
#define kHit_StartPositionOffset 0x4C // Hooks.h: HitInfo.startPosition
#define kHit_Scatter  0x5C // Hooks.h: GMPGMPFNMFP scatter

// ─── Weapon / PlayerAttributes (OB54dump.cs) ──────────────────────────────
#define kReloadNoConsumeAmmoclip 0xD8 // PlayerAttributes.ReloadNoConsumeAmmoclip
#define kShootNoReload           0xD9 // PlayerAttributes.ShootNoReload

// ─── Aim Magnet external memory ────────────────────────────────────────────
#define kMagRootNodeOffset       0x660  // OB54 Player: root ITransformNode
#define kMagBodyPartOffset       0x10   // ITransformNode: body-part Transform
#define kMagInnerOffset          0x10   // Transform wrapper: internal transform
#define kMagMatrixOffset         0x38   // Transform object: matrix pointer
#define kMagPositionOffset       0x90   // Transform matrix: world position Vector3
#define kMagMaxDisplacementValue 5.50f  // 5.0 was stable; above this entered the fake-damage zone
#define kMagTickMilliseconds     4      // Magnet worker cadence
#define kMagReleaseMilliseconds  200    // Magnet restore delay

// ─── Aim Magnet collider ────────────────────────────────────────────────────
#define kColliderManagedOffset       0xAB0 // OB54 Player: CapsuleCollider managed reference
#define kColliderNativePointerOffset 0x10  // Unity Component: native collider pointer
#define kColliderRadiusOffset        0x80  // Native CapsuleCollider: radius
#define kColliderHeightOffset        0x84  // Native CapsuleCollider: height
#define kColliderBoostRadiusValue     7.00f // Collider boost paired with 5.5 displacement
#define kColliderBoostHeightValue    14.00f // Collider boost paired with 5.5 displacement

// ─── Silent Aim external memory ────────────────────────────────────────────
#define kLastAimInfoOffset              0xDC8 // OB54 iOS Player: LastAimInfo
#define kSilentHeadNodeOffset           0x638 // OB54 Player: ITransformNode Head
#define kSilentBodyPartTransformOffset  0x10  // ITransformNode: Transform
#define kHitRayDirectionOffset          0x40  // Hooks.h HitInfo.direction
#define kHitStartPositionOffset         0x4C  // Hooks.h HitInfo.startPosition
#define kHitScatterOffset               0x5C  // Hooks.h GMPGMPFNMFP scatter

// ─── No Recoil external value scan ──────────────────────────────────────────
#define kNoRecoilOriginalValue    1016018816U // Hooks.h/GMPGMPFNMFP original value
#define kNoRecoilModifiedValue    180U        // Hooks.h/GMPGMPFNMFP active value
#define kNoRecoilScanStartAddress 0x100000000ULL // External heap scan lower bound
#define kNoRecoilScanEndAddress   0x4000000000ULL // External heap scan upper bound

// ─── Raw external UMA skeleton ──────────────────────────────────────────────
#define kUmaAvatarManagerOffset 0x708 // OB54 Player: AvatarManager m_AvatarManager
#define kUmaAvatarOffset        0x138 // OB54 AvatarManager: IUmaAvatar m_Avatar
#define kUmaDataOffsetPrimary   0x30  // UMA external chain: IUmaAvatar -> UMAData
#define kUmaDataOffsetFallback  0x38  // OB54 fallback UMAData reference
#define kUmaSkeletonOffset      0x138 // OB54 UMAData: UMASkeleton skeleton
#define kUmaBoneListOffset      0x20  // OB54 UMASkeleton: boneHashDataBackup
#define kUmaBoneDictionaryOffset 0x28 // OB54 UMASkeleton: boneHashDataLookup
#define kUmaListItemsOffset     0x10  // Unity List<T>: _items
#define kUmaListSizeOffset      0x18  // Unity List<T>: _size
#define kUmaArrayItemsOffset    0x20  // Il2CppArray: first element
#define kUmaBoneNameHashOffset  0x10  // OB54 BoneData: boneNameHash
#define kUmaBoneTransformOffset 0x18  // OB54 BoneData: Transform boneTransform
#define kUmaDictionaryEntriesOffset 0x18 // Unity Dictionary: _entries
#define kUmaDictionaryCountOffset   0x20 // Unity Dictionary: _count
#define kUmaDictionaryEntryStride   0x18 // Dictionary.Entry<int,BoneData>
#define kUmaDictionaryEntryValueOffset 0x10 // Dictionary.Entry.value

// Hashes from UMA/BaseBoneMale_Mesh boneNameHashes asset map.
#define kUmaBoneHeadHash          (-2111735698)
#define kUmaBoneNeckHash          (96688289)
#define kUmaBoneHipsHash          (1529948125)
#define kUmaBoneSpineHash         (-1051086991)
#define kUmaBoneSpine1Hash        (-1541408846)
#define kUmaBoneLeftArmHash       (1604555488)
#define kUmaBoneLeftForeArmHash   (-1129867206)
#define kUmaBoneLeftHandHash      (1892485702)
#define kUmaBoneRightArmHash      (-1391784435)
#define kUmaBoneRightForeArmHash  (1507255706)
#define kUmaBoneRightHandHash     (-1367065569)
#define kUmaBoneLeftLegUpperHash  (-285661123)
#define kUmaBoneLeftLegHash       (-1305646021)
#define kUmaBoneLeftAnkleHash     (-344692431)
#define kUmaBoneLeftToeHash       (-1258743979)
#define kUmaBoneRightLegUpperHash (952826536)
#define kUmaBoneRightLegHash      (1082519766)
#define kUmaBoneRightAnkleHash    (-115488425)
#define kUmaBoneRightToeHash      (1179749304)
