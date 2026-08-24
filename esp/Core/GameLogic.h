#ifndef GameLogic_h
#define GameLogic_h

#import "pid.h"
#import "UnityMath.h"
#pragma mark - Function Game

uint64_t getMatchGame(uint64_t Moudule_Base);
uint64_t getMatch(uint64_t matchgame);
uint64_t CameraMain(uint64_t matchgame);
float* GetViewMatrix(uint64_t cameraMain);
bool IsAtLobby(uint64_t Moudule_Base);
bool getIsVisible(uint64_t playerPawn);
uint64_t WeaponOnHand(uint64_t localPlayer);
uint64_t getTransNode(uint64_t BodyPart);
uint64_t getHead(uint64_t player);
uint64_t getHip(uint64_t player);
uint64_t getLeftAnkle(uint64_t player);
uint64_t getRightAnkle(uint64_t player);
uint64_t getRightToeNode(uint64_t player);
uint64_t getLeftToeNode(uint64_t player);
uint64_t getLeftShoulder(uint64_t player);
uint64_t getRightShoulder(uint64_t player);
uint64_t getLeftElbow(uint64_t player);
uint64_t getRightElbow(uint64_t player);
uint64_t getLeftHand(uint64_t player);
uint64_t getRightHand(uint64_t player);
uint64_t getLocalPlayer(uint64_t match);
int GetDataUInt16(uint64_t player, int varID);
void SetDataUInt16(uint64_t player, int varID, uint16_t value);
int get_CurHP(uint64_t Player);
int get_MaxHP(uint64_t Player);
bool get_IsFiring(uint64_t player);
bool isLocalTeamMate(uint64_t localPlayer, uint64_t Player);
#endif
