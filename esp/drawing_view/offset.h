#pragma once

#define kGameFacadeTypeInfo      0xBFD8978 // GameFacade type info; exception: user requested this one remain unchanged

// ─── Player / match / camera offsets ─────────────────────────────────────
#define kTypeInfoStatics         0xB8    // GameFacade.TypeInfo: static fields pointer
#define kCurrentGame             0x0     // GameFacade static: current game
#define kCurrentMatchGame        0x8     // GameFacade static: current match game
#define kMatch                   0x90    // MatchGame: Match
#define kMatchLocalPlayer        0xD8    // Match: local Player
#define kCameraControllerManager 0xD8    // MatchGame: CameraControllerManager
#define kMainCamera              0x20    // CameraControllerManager: main Camera
#define kCameraInner             0x10    // Camera: internal camera data
#define kViewMatrixOff           0x80    // Camera data: view matrix
#define kProjMatrixOff           0xC0    // Camera data: projection matrix
#define kBodyPartTransNode       0x10    // BodyPart: ITransformNode
#define kHeadNode                0x638   // Player: head ITransformNode
#define kHipNode                 0x640   // Player: hip ITransformNode
#define kLeftAnkleNode           0x670   // Player: left ankle ITransformNode
#define kRightAnkleNode          0x678   // Player: right ankle ITransformNode
#define kRightToeNode            0x688   // Player: right toe ITransformNode
#define kLeftToeNode             0x680   // Player: left toe ITransformNode
#define kLeftShoulderNode        0x658   // Player: left shoulder ITransformNode
#define kRightShoulderNode       0x660   // Player: right shoulder ITransformNode
#define kLeftHandNode            0x6B8   // Player: left hand ITransformNode
#define kRightHandNode           0x6B0   // Player: right hand ITransformNode
#define kLeftElbowNode           0x6C8   // Player: left elbow ITransformNode
#define kRightElbowNode          0x6C0   // Player: right elbow ITransformNode
#define kPlayerIDStruct          0x2D0   // Player: PlayerID struct area
#define kPlayerID                0x3A0   // Player: PlayerID
#define kUserID                 0x3A0   // Player: user ID alias
#define kIsClientBot             0x438   // Player: IsClientBot
#define kDataPool               0x70    // Player: data pool
#define kDataPoolInner          0x10    // DataPool: inner object
#define kDataPoolEntriesBase    0x20    // DataPool: entries base
#define kDataPoolEntryStride    0x8     // DataPool: entry stride
#define kDataPoolValue          0x18    // DataPool entry: value
#define kAimRotation            0x5AC   // Player: aim rotation
#define kAimRotationAux         0x5BC   // Player: auxiliary aim rotation
#define kIsFiring               0x770   // Player: firing data/state
#define _0x27276BC              0x708   // Player: AvatarManager m_AvatarManager
#define _0x28726BD              0x138   // AvatarManager: IUmaAvatar m_Avatar
#define _0x2872DCF              0x101   // IUmaAvatar data: IsVisible
#define kMainCameraTransform    0x380   // Player: main camera transform
#define kMyPhysXData            0x1B80   // Player: PhysicalCCT/physx data
#define kPhxNpeononogeo         0x20    // PhysX data: geometry object
#define kGhgState               0x10    // Geometry object: pose state
#define kKnocked                 0x1150  // Player: protected JALFABPGLNE knockdown state object
#define kKnockedDownBleeding     0x11A0  // Player: IsKnockedDownBleed
#define kKnockedDownBleedingGS   0x11A1  // Player: IsKnockDownBleedingFromGS
#define kMatchPlayerDict        0x148   // Match: player dictionary
#define kDictEntries            0x18    // Dictionary: entries array
#define kDictCount              0x20    // Dictionary: count
#define kIl2CppArrayMaxLength   0x18    // Il2CppArray: max length
#define kIl2CppArrayItems       0x20    // Il2CppArray: first item
#define kDictEntryStrideBytePlayer 24   // Dictionary player entry stride
#define kDictEntryValueOffByte 16      // Dictionary player entry: value
#define kTransformInner         0x10    // Transform object: inner
#define kTransformMatrix        0x38    // Transform inner: matrix
#define kTransformIndex         0x40    // Transform inner: matrix index
#define kMatrixList             0x18    // Transform matrix: list
#define kMatrixIndices          0x20    // Transform matrix: indices
#define kNickname               0x430   // Player: nickname
#define kStringFirstChar        0x14    // Il2CppString: first character

// ─── Weapon / PlayerAttributes ─────────────────────────────────────────────
#define _0x5BC2862              0x6D8   // Player: InventoryManager / OMELKCOGCBK
#define _0x2862BCD              0xA0    // InventoryManager: itemOnHand / CHAFOMFBKEG
#define kWeaponCostAmmo         0x7B8   // Legacy weapon field, currently unused
#define kPlayerAttributes       0x700   // Player: PlayerAttributes
#define kReloadNoConsumeAmmoclip 0xD8   // PlayerAttributes: ReloadNoConsumeAmmoclip
#define kShootNoReload          0xD9    // PlayerAttributes: ShootNoReload
#define kFollowCamera           0x628   // Player: FollowCamera
#define kFOVOffset              0x70    // FollowCamera: field of view
#define kPhysCCT                0x200   // Player: PhysicalCCT pointer
#define kPhysCCT_Velocity       0x17C   // PhysicalCCT: velocity
#define kChestNode              0x648   // Player: chest ITransformNode
#define kNeckNode               0x640   // Player: neck ITransformNode
#define kSAim1                  0x7D8   // Player: IsPrepareAttack
#define kLockAimCollider        0x140   // Player: LockAimCollider backing
#define kAimCollider_Ptr        0x6C8   // Player: AimCollider pointer
#define kFollowCamera_Ptr       0x620   // Player: FollowCamera pointer
#define kIsFire_Backing         0x7D0   // Player: IsFire backing
#define kLastAimInfo_Alt        0xDC4   // Android Player: alternate LastAimInfo
#define kLastAimInfoOffset      0xDC8   // OB54 Player: LastAimInfo field used by silent aim
#define kIsVisible_Uma          0x100   // UMA data: IsVisible
#define kUmaData                0x30    // Legacy UMA data alias
#define kHit_RayDirectionOffset 0x40    // HitInfo: direction
#define kHit_StartPositionOffset 0x4C   // HitInfo: startPosition
#define kHit_Scatter             0x5C   // HitInfo/GMPGMPFNMFP: scatter
#define kSilentBodyPartTransformOffset kBodyPartTransNode // Player body-part: ITransformNode at BodyPart+0x10
#define kSilentHeadNodeOffset         kHeadNode          // Player: head ITransformNode at 0x638
#define kHitStartPositionOffset       kHit_StartPositionOffset // HitInfo: startPosition at 0x4C
#define kHitRayDirectionOffset        kHit_RayDirectionOffset  // HitInfo: ray direction at 0x40

// ─── Raw external UMA skeleton ─────────────────────────────────────────────
#define kUmaAvatarManagerOffset 0x708  // Player: AvatarManager m_AvatarManager
#define kUmaAvatarOffset        0x138  // AvatarManager: IUmaAvatar m_Avatar
#define kUmaDataOffsetAvatarBase 0x28   // UMAAvatarBase: public UMAData umaData (OB54 dump, TypeDefIndex 1093)
#define kUmaDataOffsetPrimary   0x30   // IUmaAvatar concrete fallback: UMAData reference candidate
#define kUmaDataOffsetFallback 0x38   // IUmaAvatar concrete fallback: UMAData reference candidate
#define kUmaSkeletonOffset      0x138  // UMAData: UMASkeleton skeleton
#define kUmaBoneListOffset      0x20   // UMASkeleton: boneHashDataBackup
#define kUmaBoneDictionaryOffset 0x28  // UMASkeleton: boneHashDataLookup
#define kUmaListItemsOffset     0x10   // Unity List<T>: _items
#define kUmaListSizeOffset      0x18   // Unity List<T>: _size
#define kUmaArrayItemsOffset    0x20   // Il2CppArray: first element
#define kUmaBoneNameHashOffset  0x10   // BoneData: boneNameHash
#define kUmaBoneTransformOffset 0x18   // BoneData: boneTransform
#define kUmaDictionaryEntriesOffset 0x18 // Dictionary: entries
#define kUmaDictionaryCountOffset 0x20 // Dictionary: count
#define kUmaDictionaryEntryStride 0x18 // Dictionary.Entry<int,BoneData>
#define kUmaDictionaryEntryValueOffset 0x10 // Dictionary.Entry.value
#define kUmaBoneHeadHash          (-2111735698) // BaseBoneMale_Mesh asset: bone_Head
#define kUmaBoneNeckHash          (96688289)    // BaseBoneMale_Mesh asset: bone_Neck
#define kUmaBoneHipsHash          (1529948125)  // BaseBoneMale_Mesh asset: bone_Hips
#define kUmaBoneSpineHash         (-1051086991) // BaseBoneMale_Mesh asset: bone_Spine
#define kUmaBoneSpine1Hash        (-1541408846) // BaseBoneMale_Mesh asset: bone_Spine1
#define kUmaBoneLeftArmHash       (1604555488)  // BaseBoneMale_Mesh asset: bone_LeftArm
#define kUmaBoneLeftForeArmHash   (-1129867206) // BaseBoneMale_Mesh asset: bone_LeftForeArm
#define kUmaBoneLeftHandHash      (1892485702)  // BaseBoneMale_Mesh asset: bone_LeftHand
#define kUmaBoneRightArmHash      (-1391784435) // BaseBoneMale_Mesh asset: bone_RightArm
#define kUmaBoneRightForeArmHash  (1507255706)  // BaseBoneMale_Mesh asset: bone_RightForeArm
#define kUmaBoneRightHandHash     (-1367065569) // BaseBoneMale_Mesh asset: bone_RightHand
#define kUmaBoneLeftLegUpperHash  (-285661123)  // BaseBoneMale_Mesh asset: bone_LeftLegUpper
#define kUmaBoneLeftLegHash       (-1305646021) // BaseBoneMale_Mesh asset: bone_LeftLeg
#define kUmaBoneLeftAnkleHash     (-344692431)  // BaseBoneMale_Mesh asset: bone_LeftAnkle
#define kUmaBoneLeftToeHash       (-1258743979) // BaseBoneMale_Mesh asset: bone_LeftToe
#define kUmaBoneRightLegUpperHash (952826536)   // BaseBoneMale_Mesh asset: bone_RightLegUpper
#define kUmaBoneRightLegHash      (1082519766)  // BaseBoneMale_Mesh asset: bone_RightLeg
#define kUmaBoneRightAnkleHash    (-115488425)  // BaseBoneMale_Mesh asset: bone_RightAnkle
#define kUmaBoneRightToeHash      (1179749304)  // BaseBoneMale_Mesh asset: bone_RightToe

// ─── Runtime tuning / external scan values ─────────────────────────────────
#define kMagRootNodeOffset       0x660  // Player: root ITransformNode
#define kMagBodyPartOffset       0x10   // ITransformNode: body-part Transform
#define kMagInnerOffset          0x10   // Transform wrapper: internal transform
#define kMagMatrixOffset         0x38   // Transform object: matrix pointer
#define kMagPositionOffset       0x90   // Transform matrix: world position
#define kMagMaxDisplacementValue 5.50f  // 5.0 stable; fake damage began above this
#define kMagTickMilliseconds     4      // Magnet worker cadence
#define kMagReleaseMilliseconds  200    // Magnet release delay
#define kColliderManagedOffset       0xAB0 // Player: CapsuleCollider managed reference
#define kColliderNativePointerOffset 0x10 // Component: native pointer
#define kColliderRadiusOffset        0x80 // Native CapsuleCollider: radius
#define kColliderHeightOffset        0x84 // Native CapsuleCollider: height
#define kColliderBoostRadiusValue     7.00f // Magnet collider tuning
#define kColliderBoostHeightValue    14.00f // Magnet collider tuning
#define kNoRecoilOriginalValue    1016018816U // Legacy scan original value
#define kNoRecoilModifiedValue    180U // Legacy scan active value
#define kNoRecoilScanStartAddress 0x100000000ULL // External scan lower bound
#define kNoRecoilScanEndAddress   0x4000000000ULL // External scan upper bound
