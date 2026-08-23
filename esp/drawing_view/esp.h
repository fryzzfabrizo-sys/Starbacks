#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdint.h>

#import "../Core/GameLogic.h"

typedef struct {
    CGMutablePathRef boxPath;
    CGMutablePathRef bonePath;
    CGMutablePathRef snaplinePath;
    CGMutablePathRef hpBackgroundPath;
    CGMutablePathRef hpFillPath;
    CGMutablePathRef aimAssistPath;
    CGMutablePathRef alertPath;

CGMutablePathRef boxBotPath;
CGMutablePathRef boxPlayerPath;

CGMutablePathRef lineBotPath;
CGMutablePathRef linePlayerPath;

CGMutablePathRef boxKnockPath;
CGMutablePathRef lineKnockPath;

bool boxBotDirty;
bool boxPlayerDirty;
bool boxKnockDirty;

bool lineBotDirty;
bool linePlayerDirty;
bool lineKnockDirty;


    bool boxDirty;
    bool boneDirty;
    bool snaplineDirty;
    bool hpBackgroundDirty;
    bool hpFillDirty;
    bool aimAssistDirty;
    bool alertDirty;
} ESPGeometryBuffers;

typedef void (*ESPAddTextCallback)(
    void *context,
    NSString *string,
    CGRect frame,
    UIColor *color,
    CGFloat fontSize,
    BOOL leftAligned
);

extern bool isBox;
extern bool isBone;
extern bool isHealth;
extern bool isName;
extern bool isDis;
extern bool isLine;
extern bool isEspBot;
extern bool isWeapon;
extern bool isAimIgnoreBot;
extern bool isAimIgnoreKnock;
extern bool isAimCheckVisible;
extern bool isAimRage;
extern bool isLineAim;

extern bool isAimbot;
extern int  box;
extern int  triggerMode;
extern int  aimPosition;
extern int  aimTargetMode;
extern float aimFov;
extern float aimDistance;
extern float aimSpeed;
// Thêm vào file esp.h:
extern bool isNoReload;
extern bool isVohaDan;
extern bool isFastFire;
//phần cam cao
extern bool camcao;
extern float Campc;


// ========== THÊM MỚI: Show FOV ==========
extern bool isShowFov;
// ========================================

// ─── Silent Aim ───────────────────────────────
extern bool     aimsilent1;
extern uint64_t g_SilentBestTarget;
// ==============================================

bool get_IsBot(uint64_t PawnObject);
bool get_IsKnockedDown(uint64_t PawnObject);

UIFont *VietnameseFontForLayer(CGFloat size);

BOOL RenderFOVCirclePath(
    CGMutablePathRef path,
    float viewWidth,
    float viewHeight,
    BOOL aimbotEnabled,
    float fovRadius
);

void RenderESPForPawn(
    ESPGeometryBuffers *buffers,
    ESPAddTextCallback textCallback,
    void *callbackContext,
    uint64_t PawnObject,
    int CurHP,
    float dis,
    float *matrix,
    float layerWidth,
    float layerHeight,
    float matrixVpWidth,
    float matrixVpHeight
);

void ESPSyncFromPrefs(void);

@interface ESP_View : UIView
- (instancetype)initWithFrame:(CGRect)frame;
- (void)hideMenu;
- (void)showMenu;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
- (void)layoutSubviews;
- (void)centerMenu;
@end

@interface ESPOverlayView : UIView
- (instancetype)initWithFrame:(CGRect)frame;
@end