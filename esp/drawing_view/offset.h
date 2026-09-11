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
#define _0x5BC2862 0x6E8//protected OMELKCOGCBK LPEALCPGJBL; // 0x6D8

#define _0x2862BCD 0xA0//private NAELPAAELNO CHAFOMFBKEG; // 0xA0

#define kWeaponCostAmmo         0x7B8   // protected bool m_CostAmmo
#define kPlayerAttributes       0x700   // protected PlayerAttributes
#define kShootNoReload          0xD9    // public bool ShootNoReload
#define kFastFireOff            0x208  // Tốc độ bắn (Fast Fire)
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
#define kHit_Scatter  0x5C
