#import "GameLogic.h"
#import "../drawing_view/offset.h"
#import <Foundation/Foundation.h>
#import <math.h>
#pragma mark - Function Game

static uint64_t ReadMatchGameFromGameFacadeStatics(uint64_t GameFacade_Static) {
    if (!isVaildPtr(GameFacade_Static)) return 0;
    uint64_t matchGame = ReadAddr<uint64_t>(GameFacade_Static + (uint64_t)kCurrentMatchGame);
    if (isVaildPtr(matchGame)) return matchGame;
    return ReadAddr<uint64_t>(GameFacade_Static + (uint64_t)kCurrentGame);
}

uint64_t getMatchGame(uint64_t Moudule_Base) {
    if (!isVaildPtr((uintptr_t)Moudule_Base))
        return 0;
    uint64_t typeInfoAddr = Moudule_Base + (uint64_t)kGameFacadeTypeInfo;
    uint64_t GameFacade_TypeInfo = ReadAddr<uint64_t>(typeInfoAddr);
    uint64_t GameFacade_Static = ReadAddr<uint64_t>(GameFacade_TypeInfo + kTypeInfoStatics);
    return ReadMatchGameFromGameFacadeStatics(GameFacade_Static);
}

uint64_t getMatch(uint64_t matchgame) {
    if (!isVaildPtr((uintptr_t)matchgame)) return 0;
    return ReadAddr<uint64_t>(matchgame + kMatch);
}

uint64_t getLocalPlayer(uint64_t match) {
    if (!isVaildPtr((uintptr_t)match)) return 0;
    return ReadAddr<uint64_t>(match + kMatchLocalPlayer);
}

uint64_t WeaponOnHand(uint64_t localPlayer) {
    if (!isVaildPtr(localPlayer)) return 0;
    uint64_t inv = ReadAddr<uint64_t>(localPlayer + _0x5BC2862); // InventoryManager
    if (!isVaildPtr(inv)) return 0;
    uint64_t wpn = ReadAddr<uint64_t>(inv + _0x2862BCD);          // Item m_itemOnHand (Weapon*)
    return isVaildPtr(wpn) ? wpn : 0;
}

uint64_t CameraMain(uint64_t matchgame) {
    if (!isVaildPtr((uintptr_t)matchgame)) return 0;
    uint64_t CameraControllerManager = ReadAddr<uint64_t>(matchgame + kCameraControllerManager);
    if (!isVaildPtr((uintptr_t)CameraControllerManager)) return 0;
    return ReadAddr<uint64_t>(CameraControllerManager + kMainCamera);
}

bool getIsVisible(uint64_t playerPawn) {
    // 🟢 Cải thiện tốc độ check visible
    if (playerPawn == 0) return false;
    uint64_t AvatarManager = ReadAddr<uint64_t>(playerPawn + _0x27276BC);
    if (AvatarManager == 0) return false;
    uint64_t IUmaAvatar = ReadAddr<uint64_t>(AvatarManager + _0x28726BD);
    if (IUmaAvatar == 0) return false;
    return ReadAddr<bool>(IUmaAvatar + _0x2872DCF);
}

static void TipaReadMatrix16(uint64_t addr, float *out) {
    for (int i = 0; i < 16; i++)
        out[i] = ReadAddr<float>(addr + (uint64_t)i * 4u);
}

static void TipaMultiply4x4(const float *P, const float *V, float *out) {
    for (int col = 0; col < 4; col++) {
        for (int row = 0; row < 4; row++) {
            float s = 0;
            for (int k = 0; k < 4; k++)
                s += P[k * 4 + row] * V[col * 4 + k];
            out[col * 4 + row] = s;
        }
    }
}

// 🟢 QUAN TRỌNG: Đã xóa bỏ cache Matrix. Tính toán lại ngay mỗi frame để bám sát địch.
float* GetViewMatrix(uint64_t cameraMain) {
    if (!isVaildPtr((uintptr_t)cameraMain))
        return nullptr;
    uint64_t v1 = ReadAddr<uint64_t>(cameraMain + kCameraInner);
    if (!isVaildPtr((uintptr_t)v1))
        return nullptr;
    float V[16], P[16];
    TipaReadMatrix16(v1 + kViewMatrixOff, V);
    TipaReadMatrix16(v1 + kProjMatrixOff, P);

    static float matrix[16];
    TipaMultiply4x4(P, V, matrix);
    return matrix;
}

bool IsAtLobby(uint64_t Moudule_Base) {
    if (!isVaildPtr((uintptr_t)Moudule_Base)) return true;
    uint64_t typeInfoAddr = Moudule_Base + (uint64_t)kGameFacadeTypeInfo;
    uint64_t GameFacade_TypeInfo = ReadAddr<uint64_t>(typeInfoAddr);
    if (!isVaildPtr(GameFacade_TypeInfo))
        return true;
    uint64_t GameFacade_Static = ReadAddr<uint64_t>(GameFacade_TypeInfo + kTypeInfoStatics);
    if (!isVaildPtr(GameFacade_Static))
        return true;
    uint64_t matchGame = ReadMatchGameFromGameFacadeStatics(GameFacade_Static);
    bool inLobby = !isVaildPtr(matchGame);
    return inLobby;
}

uint64_t getTransNode(uint64_t BodyPart) {
    if (!isVaildPtr((uintptr_t)BodyPart)) return 0;
    uint64_t node = ReadAddr<uint64_t>(BodyPart + kBodyPartTransNode);
    if (!isVaildPtr((uintptr_t)node)) return 0;
    return node;
}

static uint64_t getBoneTrans(uint64_t player, uintptr_t nodeOffset) {
    if (!isVaildPtr((uintptr_t)player)) return 0;
    uint64_t BodyPart = ReadAddr<uint64_t>(player + nodeOffset);
    if (!isVaildPtr((uintptr_t)BodyPart)) return 0;
    return getTransNode(BodyPart);
}

uint64_t getHead(uint64_t player) { return getBoneTrans(player, kHeadNode); }
uint64_t getHip(uint64_t player) { return getBoneTrans(player, kHipNode); }
uint64_t getLeftAnkle(uint64_t player) { return getBoneTrans(player, kLeftAnkleNode); }
uint64_t getRightAnkle(uint64_t player) { return getBoneTrans(player, kRightAnkleNode); }
uint64_t getRightToeNode(uint64_t player) { return getBoneTrans(player, kRightToeNode); }
uint64_t getLeftToeNode(uint64_t player) { return getBoneTrans(player, kLeftToeNode); }
uint64_t getLeftShoulder(uint64_t player) { return getBoneTrans(player, kLeftShoulderNode); }
uint64_t getLeftElbow(uint64_t player) { return getBoneTrans(player, kLeftElbowNode); }
uint64_t getLeftHand(uint64_t player) { return getBoneTrans(player, kLeftHandNode); }
uint64_t getRightShoulder(uint64_t player) { return getBoneTrans(player, kRightShoulderNode); }
uint64_t getRightElbow(uint64_t player) { return getBoneTrans(player, kRightElbowNode); }
uint64_t getRightHand(uint64_t player) { return getBoneTrans(player, kRightHandNode); }

bool isLocalTeamMate(uint64_t localPlayer, uint64_t Player) {
    if (!isVaildPtr(localPlayer) || !isVaildPtr(Player)) return false;
    COW_GamePlay_PlayerID_o myPlayerID = ReadAddr<COW_GamePlay_PlayerID_o>(localPlayer + kPlayerID);
    COW_GamePlay_PlayerID_o PlayerID = ReadAddr<COW_GamePlay_PlayerID_o>(Player + kPlayerID);
    int myTeamID = myPlayerID.m_TeamID;
    int TeamID = PlayerID.m_TeamID;
    return myTeamID == TeamID;
}

int GetDataUInt16(uint64_t player, int varID) {
    if (!isVaildPtr(player)) return 0;
    uint64_t IPRIDataPool = ReadAddr<uint64_t>(player + kDataPool);
    if (!isVaildPtr(IPRIDataPool)) return 0;
    uint64_t v2 = ReadAddr<uint64_t>(IPRIDataPool + kDataPoolInner);
    if (!isVaildPtr(v2)) return 0;
    uint64_t v4 = ReadAddr<uint64_t>(v2 + kDataPoolEntryStride * (uint64_t)varID + kDataPoolEntriesBase);
    if (!isVaildPtr(v4)) return 0;
    return ReadAddr<int>(v4 + kDataPoolValue);
}

void SetDataUInt16(uint64_t player, int varID, uint16_t value) {
    if (!isVaildPtr(player)) return;
    uint64_t IPRIDataPool = ReadAddr<uint64_t>(player + kDataPool);
    if (!isVaildPtr(IPRIDataPool)) return;
    uint64_t v2 = ReadAddr<uint64_t>(IPRIDataPool + kDataPoolInner);
    if (!isVaildPtr(v2)) return;
    uint64_t v4 = ReadAddr<uint64_t>(v2 + kDataPoolEntryStride * (uint64_t)varID + kDataPoolEntriesBase);
    if (!isVaildPtr(v4)) return;
    WriteAddr<uint16_t>(v4 + kDataPoolValue, value);
}

int get_CurHP(uint64_t Player) { return GetDataUInt16(Player, 0); }
int get_MaxHP(uint64_t Player) { return GetDataUInt16(Player, 1); }
