#import "esp.h"
#import "ESPPrefs.h"
#import "../drawing_view/offset.h"
#import "mahoa.h"
#import "../../sources/silent.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <notify.h>

#include <stdlib.h>
#include <sys/mman.h>
#include <string>
#include <vector>
#include <cmath>
#include <float.h>

uint64_t Moudule_Base = -1;

// ─── ESP Flags ────────────────────────────────
bool isBox      = YES;
bool isCount     = YES;
bool isHealth   = YES;
bool isName     = YES;
bool isDis      = YES;
bool isLine     = YES;
bool isEspBot   = NO;
bool isWeapon   = NO;
bool BackJump = NO;
bool isBone = NO;
bool Norecoil = NO;
bool camcao = NO;
bool hoihp = NO;
bool danthg = NO;
bool testGhost = NO;
bool dunhanh = NO;

// ========== THÊM MỚI: 3 chức năng Memory ==========
bool isNoReload    = NO;
bool isVohaDan     = NO;
bool isFastFire    = NO;
// ==================================================

// ========== THÊM MỚI: Show FOV ==========
bool isShowFov = YES;
// ========================================

// ─── Silent Aim ──────────────────────────────
bool aimsilent1 = NO;
uint64_t g_SilentBestTarget = 0;
// ==================================================

// ─── Aimbot Flags 
//─────────────────────────────
bool isAimbot          = NO;
bool isAimIgnoreBot    = NO;
bool isAimIgnoreKnock  = NO;
bool isAimCheckVisible = NO;
bool isAimRage         = NO;
bool isLineAim         = YES;


int   box    = 0;
int   triggerMode    = 0;
int   aimPosition    = 0;
int   aimTargetMode  = 0;
float aimFov         = 150.0f;
float aimDistance    = 200.0f;
float aimSpeed       = 1.0f;
float traiphai = 0.4f;

float Campc = 0.0f;
float speedvalue = 1.0f;

static uint64_t s_lastFollowCameraObj = 0;

static bool gESPPrefsLoadedOnce = false;

void ESPSyncFromPrefs(void) {
    isBox    = ESPPrefsBool(NSSENCRYPT("Box"),    NO);
    isCount   = ESPPrefsBool(NSSENCRYPT("Count"),   NO);
    isHealth = ESPPrefsBool(NSSENCRYPT("Health"), NO);
    isName   = ESPPrefsBool(NSSENCRYPT("Name"),   NO);
    isDis      = ESPPrefsBool(NSSENCRYPT("Dis"),   NO);

    dunhanh = ESPPrefsBool(NSSENCRYPT("dunhanh"), NO);

   
    testGhost = ESPPrefsBool(NSSENCRYPT("testGhost"),    NO);


    camcao = ESPPrefsBool(NSSENCRYPT("camcao"),    NO);
   
    hoihp = ESPPrefsBool(NSSENCRYPT("hoihp"),    NO);

    danthg = ESPPrefsBool(NSSENCRYPT("danthg"),    NO);


    Norecoil    = ESPPrefsBool(NSSENCRYPT("Norecoil"),    NO);
    isBone   =  ESPPrefsBool(NSSENCRYPT("Bone"),   NO);
    isLine   = ESPPrefsBool(NSSENCRYPT("Line"),   NO);
    isEspBot = ESPPrefsBool(NSSENCRYPT("EspBot"), NO);
    BackJump = ESPPrefsBool(NSSENCRYPT("BackJump"), NO);
    isAimIgnoreBot    = ESPPrefsBool(NSSENCRYPT("AimIgnoreBot"),    NO);
    isAimIgnoreKnock  = ESPPrefsBool(NSSENCRYPT("AimIgnoreKnock"), NO);
    isAimCheckVisible = ESPPrefsBool(NSSENCRYPT("AimCheckVisible"), NO);
    isAimRage         = ESPPrefsBool(NSSENCRYPT("AimRage"),         NO);
    isLineAim         = ESPPrefsBool(NSSENCRYPT("LineAim"),         YES);
    isAimbot          = ESPPrefsBool(NSSENCRYPT("Aimbot"),          NO);

    // ========== THÊM MỚI: Load 3 chức năng Memory ==========
    isNoReload = ESPPrefsBool(NSSENCRYPT("NoReload"), NO);
    isVohaDan  = ESPPrefsBool(NSSENCRYPT("VohaDan"), NO);
    isFastFire = ESPPrefsBool(NSSENCRYPT("FastFire"), NO);
    // ========================================================

    // ========== THÊM MỚI ==========
    isShowFov = ESPPrefsBool(NSSENCRYPT("ShowFov"), YES);
    aimsilent1 = ESPPrefsBool(NSSENCRYPT("SilentAim"), NO);
    // ===============================


box = (int)ESPPrefsFloat(NSSENCRYPT("box"), 0.0f);
    if (box < 0 || box > 1) box = 0;

    triggerMode = (int)ESPPrefsFloat(NSSENCRYPT("TriggerMode"), 0.0f);
    if (triggerMode < 0 || triggerMode > 3) triggerMode = 0;

    aimPosition = (int)ESPPrefsFloat(NSSENCRYPT("AimPos"), 0.0f);
    if (aimPosition < 0 || aimPosition > 2) aimPosition = 0;

    aimTargetMode = (int)ESPPrefsFloat(NSSENCRYPT("AimTargetMode"), 0.0f);
    if (aimTargetMode < 0 || aimTargetMode > 2) aimTargetMode = 0;

    speedvalue = ESPPrefsFloat(NSSENCRYPT("speed"), 1.0f);
    speedvalue = fmaxf(1.0f, fminf(speedvalue, 1.9f));

    Campc = ESPPrefsFloat(NSSENCRYPT("Campc"), 1.0f);
    Campc = fmaxf(1.0f, fminf(Campc, 100.0f));

    traiphai = ESPPrefsFloat(NSSENCRYPT("traiphai"), 0.4f);
    traiphai = fmaxf(0.4f, fminf(traiphai, 1.2f));

    aimFov = ESPPrefsFloat(NSSENCRYPT("Fov"), 150.0f);
    aimFov = fmaxf(10.0f, fminf(aimFov, 500.0f));

    aimDistance = ESPPrefsFloat(NSSENCRYPT("Distance"), 200.0f);

    aimSpeed = ESPPrefsFloat(NSSENCRYPT("AimSpeed"), 100.0f) / 100.0f;
    aimSpeed = fmaxf(0.01f, fminf(aimSpeed, 1.0f));
}

// ─── Aim Lock State ───────────────────────────
static uint64_t    gAimLockTarget         = 0;
static int         gAimLockLostFrames     = 0;
static const int   kAimLockMaxLostFrames  = 10;
static const NSUInteger kMaxTextLayerPoolSize = 128;

struct COW_GamePlay_IHAAMHPPLMG_o {
 uint32_t NBPDJAAAFBH;
 uint32_t JEDDPHIHGKL;
 uint8_t IOICFFEKAIL;
 uint8_t PHAFNFOFFDB;
 uint64_t BNFAIDHEHOM;
};

COW_GamePlay_IHAAMHPPLMG_o originalPlayerID;
BOOL hasSavedOriginalID = false;
// ─── Frame Cache ──────────────────────────────
static uint64_t cachedMatchGame  = 0;
static uint64_t cachedCamera     = 0;
uint64_t cachedMatch      = 0;
static int      cacheRefreshTick = 0;

typedef struct {
    int playerCount;
    int botCount;
    bool inMatch;
} ESPFrameStats;
// ─── Helpers ──────────────────────────────────
static inline float Clamp01f(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

static inline void ESPReleasePath(CGMutablePathRef p) { if (p) CGPathRelease(p); }

static inline ESPGeometryBuffers ESPGeometryBuffersCreate(void) {
    ESPGeometryBuffers b;
    //b.boxPath          = CGPathCreateMutable();

b.boxBotPath    = CGPathCreateMutable();
b.boxPlayerPath = CGPathCreateMutable();
b.boxKnockPath    = CGPathCreateMutable();

b.lineKnockPath    = CGPathCreateMutable();
b.lineBotPath    = CGPathCreateMutable();
b.linePlayerPath = CGPathCreateMutable();




    b.bonePath         = CGPathCreateMutable();
    b.snaplinePath     = CGPathCreateMutable();
    b.hpBackgroundPath = CGPathCreateMutable();
    b.hpFillPath       = CGPathCreateMutable();
    b.aimAssistPath    = CGPathCreateMutable();
    b.alertPath        = CGPathCreateMutable();
    b.boxBotDirty = b.boneDirty = b.lineBotDirty      = NO;
   
    b.hpBackgroundDirty = b.hpFillDirty             = NO;
    b.aimAssistDirty = b.alertDirty                 = NO;
    return b;
}

static inline void ESPGeometryBuffersRelease(ESPGeometryBuffers *b) {
    if (!b) return;
    ESPReleasePath(b->boxBotPath);
    ESPReleasePath(b->lineBotPath);
    ESPReleasePath(b->boxPlayerPath);
    ESPReleasePath(b->linePlayerPath);
    ESPReleasePath(b->boxKnockPath);
    ESPReleasePath(b->lineKnockPath);
    
    ESPReleasePath(b->bonePath);
    ESPReleasePath(b->snaplinePath);
    ESPReleasePath(b->hpBackgroundPath);
    ESPReleasePath(b->hpFillPath);
    ESPReleasePath(b->aimAssistPath);
    ESPReleasePath(b->alertPath);
}

static inline void ApplyPath(CAShapeLayer *layer, CGMutablePathRef path, bool dirty) {
    if (layer) layer.path = (dirty && path) ? path : nil;
}

// ─── Box ──────────────────────────────────────
static inline void ESPAddBox(CGMutablePathRef path, CGRect rect) {
    if (path) CGPathAddRect(path, NULL, rect);
}

// ─── Snapline ──
static inline void ESPAddSnapline(CGMutablePathRef path, CGPoint start, CGPoint end) {
    if (path) {
        CGPathMoveToPoint(path, NULL, start.x, start.y);
        CGPathAddLineToPoint(path, NULL, end.x, end.y);
    }
}

// ─── Thanh máu ────────────────────────────────
static inline void ESPAddHealthBar(CGMutablePathRef bgPath, CGMutablePathRef fillPath,
                                   CGRect boxRect, float hp) {
    if (!bgPath || !fillPath) return;

    const CGFloat barW = 2.0f;      // 🟢 Tăng độ dày thanh máu
    const CGFloat gap   = 3.0f;     // 🟢 Tách xa box hơn (từ 1.5f lên 3.0f)
    const CGFloat bdr   = 0.8f;     // 🟢 Viền đen dày hơn

    CGFloat x = boxRect.origin.x - gap - barW;
    CGFloat y = boxRect.origin.y;
    CGFloat h = boxRect.size.height;

    // 🟢 Chỉ vẽ viền đen bao quanh (không fill nền)
    CGPathAddRect(bgPath, NULL,
        CGRectMake(x - bdr, y - bdr, barW + bdr * 2.0f, h + bdr * 2.0f));

    // 🟢 Fill màu xanh bên trong (chỉ phần máu còn lại)
    CGFloat fillH = h * Clamp01f(hp);
    CGFloat fillY = y + (h - fillH);
    if (fillH > 0.5f)
        CGPathAddRect(fillPath, NULL, CGRectMake(x, fillY, barW, fillH));
    // 🟢 Khi mất máu, phần dưới không có fill → trong suốt
}

static inline BOOL RenderFOVCirclePath(CGMutablePathRef path,
                                        CGFloat vw, CGFloat vh,
                                        BOOL aiming, float fov) {
    if (!aiming || fov <= 0) return NO;
    CGPathAddArc(path, NULL, vw / 2.0f, vh / 2.0f, fov, 0, M_PI * 2, YES);
    return YES;
}

// ─────────────────────────────────────────────
// MARK: - ESP_View Interface
// ─────────────────────────────────────────────
@interface ESP_View ()
@property (nonatomic, strong) CADisplayLink          *displayLink;
@property (nonatomic, strong) CAShapeLayer           *boxLayer;
@property (nonatomic, strong) CAShapeLayer           *boneLayer;
@property (nonatomic, strong) CAShapeLayer           *snaplineLayer;
@property (nonatomic, strong) CAShapeLayer           *hpBackgroundLayer;
@property (nonatomic, strong) CAShapeLayer           *hpFillLayer;
@property (nonatomic, strong) CAShapeLayer           *aimAssistLayer;
@property (nonatomic, strong) CAShapeLayer           *alertLayer;
@property (nonatomic, strong) CAShapeLayer           *fovLayer;
@property (nonatomic, strong) NSMutableArray<CATextLayer *> *textLayerPool;
@property (nonatomic, assign) NSUInteger              activeTextLayerCount;
@property (nonatomic, strong) CATextLayer            *statusLayer;

@property(nonatomic,strong) CAShapeLayer *boxBotLayer;
@property(nonatomic,strong) CAShapeLayer *boxPlayerLayer;

@property(nonatomic,strong) CAShapeLayer *lineBotLayer;
@property(nonatomic,strong) CAShapeLayer *linePlayerLayer;

@property(nonatomic,strong) CAShapeLayer *boxKnockLayer;
@property(nonatomic,strong) CAShapeLayer *lineKnockLayer;

@end

// ─────────────────────────────────────────────
// MARK: - ESP_View Implementation
// ─────────────────────────────────────────────
@implementation ESP_View

- (void)showMenu              { }
- (void)hideMenu              { }
- (void)centerMenu            { }
- (void)handlePan:(UIPanGestureRecognizer *)g { }

// ─── FIX TOẠ ĐỘ VÀ SIZE CHỮ KHÔNG BỊ PHÌNH TO / LỆCH XA GẦN ───
static void ESPTextCallback(void *ctx, NSString *str, CGRect frame,
                                UIColor *color, CGFloat fontSize, BOOL leftAligned) {
    if (!ctx || !str) return;
    ESP_View *view = (__bridge ESP_View *)ctx;
    
    CGRect f = CGRectMake(frame.origin.x,
                          frame.origin.y,
                          frame.size.width,
                          frame.size.height);

    CGFloat finalSize = fontSize;
    if ([str hasPrefix:@"["] || [str hasSuffix:@"]"]) {
        finalSize = 7.5f;
    } else {
        finalSize = 9.0f;
    }

    [view addText:str frame:f
            color:color
         fontSize:finalSize leftAligned:leftAligned];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = NO;
    self.backgroundColor        = UIColor.clearColor;
    self.textLayerPool          = [NSMutableArray array];

    [self configureRenderingLayers];
    [self setupModuleBase];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateFrame)];
    // 🟢 FPS 60 - ĐÂY LÀ CỐT LÕI ĐỂ HẾT NHÁY: Chạy 60fps thay vì 120fps.
    // 60fps đủ mượt, nhưng giảm tải CPU 50% → Hết giật chấp chấp!
    if (@available(iOS 15.0, *))
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(50.0, 60.0, 60.0);
    else if (@available(iOS 10.0, *))
        self.displayLink.preferredFramesPerSecond = 60; 
    
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.superview) self.frame = self.superview.bounds;
}

- (void)setupModuleBase {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Moudule_Base = (uint64_t)GetGameModule_Base((char *)"FreeFire");
    });
}

// ─── Layer Factory ────────────────────────────
- (CAShapeLayer *)makeShapeLayer:(UIColor *)stroke fill:(UIColor *)fill
                        lineWidth:(CGFloat)lw zPos:(CGFloat)z {
    CAShapeLayer *l   = [CAShapeLayer layer];
    l.strokeColor     = stroke ? stroke.CGColor : nil;
    l.fillColor       = fill   ? fill.CGColor   : UIColor.clearColor.CGColor;
    l.lineWidth       = lw;
    l.lineJoin        = kCALineJoinMiter;
    l.lineCap         = kCALineCapSquare;
    l.contentsScale   = UIScreen.mainScreen.scale;
    l.zPosition       = z;
    l.allowsEdgeAntialiasing = NO;
    l.actions = @{ @"path": NSNull.null };
    return l;
}

- (void)configureRenderingLayers {
    UIColor *white  = UIColor.whiteColor;
    UIColor *clear  = UIColor.clearColor;
    UIColor *hpGreen = [UIColor colorWithRed:0.0f green:0.85f blue:0.2f alpha:1.0f];

// 🟢 SỬA MÀU: Xanh lá cho box, fov. Trắng cho bone.
UIColor *green =
[UIColor colorWithRed:0.0f
                green:0.85f
                 blue:0.2f
                alpha:1.0f];

UIColor *red =
[UIColor colorWithRed:1.0f
                green:0.0f
                 blue:0.0f
                alpha:1.0f];

UIColor *boneWhite = [UIColor whiteColor]; // 🟢 Màu trắng cho bone

// Line giữ nguyên màu trắng, line gục màu đỏ
self.lineKnockLayer =
[self makeShapeLayer:red
                fill:nil
           lineWidth:0.7f // 🟢 Tăng độ dày line lên 1.2f
                zPos:1];

self.lineBotLayer =
[self makeShapeLayer:white
                fill:nil
           lineWidth:0.7f // 🟢 Tăng độ dày line lên 1.2f
                zPos:1];

self.linePlayerLayer =
[self makeShapeLayer:white
                fill:nil
           lineWidth:0.7f // 🟢 Tăng độ dày line lên 1.2f
                zPos:1];

// 🟢 SỬA: Box bình thường màu xanh lá, tăng nét lên 1.2f
self.boxBotLayer =
[self makeShapeLayer:green
                fill:nil
           lineWidth:0.7f 
                zPos:3];

self.boxPlayerLayer =
[self makeShapeLayer:green
                fill:nil
           lineWidth:0.7f
                zPos:3];

// 🟢 SỬA: Box gục màu đỏ, tăng nét lên 1.2f
self.boxKnockLayer =
[self makeShapeLayer:red
                fill:nil
           lineWidth:0.7f 
                zPos:1];

// 🟢 SỬA: FOV màu xanh lá
    self.fovLayer = [self makeShapeLayer:green
                                fill:nil
                           lineWidth:0.7f
                                zPos:0];
    self.snaplineLayer     = [self makeShapeLayer:white   fill:nil     lineWidth:0.7f zPos:1];
    
    // 🟢 SỬA: Bone màu trắng, tăng nét lên 1.2f
    self.boneLayer         = [self makeShapeLayer:boneWhite     fill:nil     lineWidth:0.7f zPos:2];
    
    self.boxLayer          = [self makeShapeLayer:white   fill:nil     lineWidth:0.7f zPos:3];
    
    // 🟢 SỬA: Nền thanh máu là viền đen (không fill)
    self.hpBackgroundLayer = [self makeShapeLayer:[UIColor blackColor] fill:nil lineWidth:0.8f zPos:4];
    // 🟢 SỬA: Fill thanh máu màu xanh (không viền)
    self.hpFillLayer       = [self makeShapeLayer:nil fill:hpGreen lineWidth:0 zPos:5];

    for (CAShapeLayer *l in @[self.fovLayer, self.snaplineLayer, self.boneLayer, self.boxLayer,
                               self.hpBackgroundLayer, self.hpFillLayer,
                            self.boxBotLayer, self.boxPlayerLayer, self.lineBotLayer, self.linePlayerLayer, self.lineKnockLayer, self.boxKnockLayer])
        [self.layer addSublayer:l];
       

    self.statusLayer = [CATextLayer layer];
    // Sẽ đổi màu động trong updateFrame
    self.statusLayer.foregroundColor =
[UIColor whiteColor].CGColor;
    self.statusLayer.alignmentMode   = kCAAlignmentCenter;
    self.statusLayer.fontSize        = 16.0f;
    self.statusLayer.font = (__bridge CFTypeRef)[UIFont systemFontOfSize:16.0f weight:UIFontWeightBold];
    self.statusLayer.shadowColor     = UIColor.blackColor.CGColor;
self.statusLayer.shadowOffset    = CGSizeMake(1.5f, 1.5f);
self.statusLayer.shadowOpacity   = 1.0f;
self.statusLayer.shadowRadius    = 1.0f;
    self.statusLayer.contentsScale   = UIScreen.mainScreen.scale;
    self.statusLayer.zPosition       = 8;
    self.statusLayer.actions = @{ @"string":NSNull.null, @"frame":NSNull.null, @"hidden":NSNull.null };
    [self.layer addSublayer:self.statusLayer];
}

- (void)resetTextLayers {
    for (CATextLayer *l in self.textLayerPool) l.hidden = YES;
    self.activeTextLayerCount = 0;
}

- (CATextLayer *)dequeueTextLayer {
    CATextLayer *layer;
    if (self.activeTextLayerCount < self.textLayerPool.count) {
        layer = self.textLayerPool[self.activeTextLayerCount];
    } else if (self.textLayerPool.count < kMaxTextLayerPoolSize) {
        layer = [CATextLayer layer];
        layer.contentsScale = UIScreen.mainScreen.scale;
        layer.alignmentMode = kCAAlignmentCenter;
        layer.shadowColor   = UIColor.blackColor.CGColor;
        layer.shadowOffset  = CGSizeMake(0.5f, 0.5f);
        layer.shadowOpacity = 1.0f;
        layer.shadowRadius  = 0.0f;
        layer.actions = @{ @"position":NSNull.null, @"bounds":NSNull.null,
                           @"string":NSNull.null,   @"hidden":NSNull.null };
        [self.textLayerPool addObject:layer];
        [self.layer addSublayer:layer];
    } else {
        layer = self.textLayerPool.lastObject;
    }
    layer.hidden = NO;
    self.activeTextLayerCount++;
    return layer;
}

- (void)addText:(NSString *)text frame:(CGRect)frame color:(UIColor *)color
       fontSize:(CGFloat)fontSize leftAligned:(BOOL)leftAligned {
    if (!text.length) return;
    CGFloat fs        = (fontSize > 0) ? fontSize : 9.0f;
    CATextLayer *l    = [self dequeueTextLayer];
    l.string          = text;
    l.frame           = frame;
    l.foregroundColor = color.CGColor;
    l.fontSize        = fs;
    l.font = (__bridge CFTypeRef)[UIFont systemFontOfSize:fs weight:UIFontWeightBold];
    l.alignmentMode   = leftAligned ? kCAAlignmentLeft : kCAAlignmentCenter;
    l.shadowColor     = UIColor.blackColor.CGColor;
    l.shadowOffset    = CGSizeMake(0.5f, 0.5f);
    l.shadowOpacity   = 1.0f;
    l.shadowRadius    = 0.0f;
}

- (void)updateFrame {
    if (!self.window) return;
    @autoreleasepool {
#ifdef NOTIFY_DESTROY_HUD
        if (GetGameProcesspid((char *)"FreeFire") == -1) {
            notify_post(NOTIFY_DESTROY_HUD);
            exit(0);
        }
#endif
        if (Moudule_Base == (uint64_t)-1)
            Moudule_Base = (uint64_t)GetGameModule_Base((char *)"FreeFire");

        if (!gESPPrefsLoadedOnce) {
            ESPSyncFromPrefs();
            gESPPrefsLoadedOnce = true;
        }

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [self resetTextLayers];

        CGFloat vw    = self.bounds.size.width;
        CGFloat vh    = self.bounds.size.height;
        CGFloat scale = self.contentScaleFactor > 0.01f ? self.contentScaleFactor : 1.0f;
        CGFloat vpW   = vw * scale;
        CGFloat vpH   = vh * scale;

        ESPGeometryBuffers buffers = ESPGeometryBuffersCreate();
        ESPFrameStats stats = [self renderESPWithBuffers:&buffers
                                               viewWidth:vw viewHeight:vh
                                           matrixVpWidth:vpW matrixVpHeight:vpH];

        ApplyPath(self.boneLayer,         buffers.bonePath,         buffers.boneDirty);
        ApplyPath(self.snaplineLayer,     buffers.snaplinePath,     buffers.snaplineDirty);
        ApplyPath(self.hpBackgroundLayer, buffers.hpBackgroundPath, buffers.hpBackgroundDirty);
        ApplyPath(self.hpFillLayer,       buffers.hpFillPath,       buffers.hpFillDirty);

ApplyPath(self.boxKnockLayer,
          buffers.boxKnockPath,
          buffers.boxKnockDirty);

ApplyPath(self.lineKnockLayer,
          buffers.lineKnockPath,
          buffers.lineKnockDirty);



ApplyPath(self.boxBotLayer,
          buffers.boxBotPath,
          buffers.boxBotDirty);

ApplyPath(self.boxPlayerLayer,
          buffers.boxPlayerPath,
          buffers.boxPlayerDirty);

ApplyPath(self.lineBotLayer,
          buffers.lineBotPath,
          buffers.lineBotDirty);

ApplyPath(self.linePlayerLayer,
          buffers.linePlayerPath,
          buffers.linePlayerDirty);



        ESPGeometryBuffersRelease(&buffers);

        if (stats.inMatch) {
            CGMutablePathRef fovPath = CGPathCreateMutable();
            BOOL hasFov = RenderFOVCirclePath(fovPath, vw, vh, ((isAimbot || aimsilent1) && isShowFov), aimFov);
            self.fovLayer.path = hasFov ? fovPath : nil;
            CGPathRelease(fovPath);

// 🟢 SỬA: Logic hiển thị CLEAR / Player count (giảm font CLEAR)
if (isCount) {
    int totalEnemies = stats.playerCount + stats.botCount;
    if (totalEnemies == 0) {
        // Không có địch -> Hiện CLEAR màu xanh ngọc, font 20
        self.statusLayer.string = @"CLEAR";
        self.statusLayer.foregroundColor = [UIColor colorWithRed:0.0f green:0.85f blue:0.9f alpha:1.0f].CGColor;
        self.statusLayer.fontSize = 20.0f;
        self.statusLayer.frame = CGRectMake(vw / 2.0f - 100.0f, 60.0f, 200.0f, 30.0f);
        self.statusLayer.hidden = NO;
    } else {
        // Có địch -> Hiện số địch
        self.statusLayer.string =
        [NSString stringWithFormat:@"Player : %d", totalEnemies];
        self.statusLayer.foregroundColor =
        [UIColor whiteColor].CGColor;

        self.statusLayer.fontSize = 20.0f;
        self.statusLayer.font = (__bridge CFTypeRef)[UIFont systemFontOfSize:20.0f weight:UIFontWeightBold];

        self.statusLayer.frame =
        CGRectMake(vw / 2.0f - 120.0f,
                   60.0f,
                   240.0f,
                   30.0f);

        self.statusLayer.hidden = NO;
    }
} else {
    self.statusLayer.hidden = YES;
}

        } else {
            [self clearAllContent];
        }

        [CATransaction commit];
    }
}

- (void)clearAllContent {
    self.boxLayer.path = self.boneLayer.path = self.snaplineLayer.path = self.lineBotLayer.path = self.linePlayerLayer.path = self.boxBotLayer.path = self.boxPlayerLayer.path = nil;
    self.hpBackgroundLayer.path = self.hpFillLayer.path                 = nil;
    self.aimAssistLayer.path = self.alertLayer.path = self.fovLayer.path = nil;
    self.statusLayer.hidden = YES;
    [self resetTextLayers];
}

- (void)dealloc {
    [_displayLink invalidate];
    _displayLink = nil;
}

// ─── C++ Helpers ──────────────────────────────
Quaternion GetRotationToLocation(Vector3 target, float yBias, Vector3 myLoc) {
    return Quaternion::LookRotation((target + Vector3(0, yBias, 0)) - myLoc, Vector3(0, 1, 0));
}

static inline bool IsZeroVec(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

Vector3 GetAimTargetPos(Vector3 head, Vector3 hip, int setting) {
    if (IsZeroVec(head) || IsZeroVec(hip)) return head;
    if (setting == 0) return head;
    if (setting == 1) {
        Vector3 neck(head.x * 0.85f + hip.x * 0.15f,
                     head.y * 0.85f + hip.y * 0.15f,
                     head.z * 0.85f + hip.z * 0.15f);
        neck.y -= 0.1f;
        return neck;
    }
    return Vector3(head.x * 0.4f + hip.x * 0.6f,
                   head.y * 0.4f + hip.y * 0.6f,
                   head.z * 0.4f + hip.z * 0.6f);
}

bool get_IsBot(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    return ReadAddr<uint8_t>(player + (uint64_t)kIsClientBot) != 0;
}

bool get_IsKnockedDown(uint64_t player) {
    if (!isVaildPtr(player)) return false;
    if (get_CurHP(player) <= 0) return false;
    uint64_t phx = ReadAddr<uint64_t>(player + kMyPhysXData);
    if (isVaildPtr(phx)) {
        uint64_t ghg = ReadAddr<uint64_t>(phx + (uint64_t)kPhxNpeononogeo);
        if (isVaildPtr(ghg) && ReadAddr<uint32_t>(ghg + (uint64_t)kGhgState) == 8)
            return true;
    }
    return ReadAddr<uint8_t>(player + kKnocked) != 0;
}

void set_aim(uint64_t player, Quaternion rotation, float targetDist) {
    if (!isVaildPtr(player)) return;
    Quaternion q       = Quaternion::Normalized(rotation);
    Quaternion current = ReadAddr<Quaternion>(player + kAimRotation);
    float angle        = Quaternion::Angle(current, q);
    if (angle < 0.0005f) return;

    float t;

    // 🟢 TĂNG TỐC ĐỘ AIM GẤP ĐÔI: Khi bắn, aim ngay lập tức (1.0f)
    bool isFiring = get_IsFiring(player);
    
    if (isAimRage || isFiring) {
        t = 1.0f; // 🟢 Aim ngay lập tức khi bắn (Gấp đôi so với trước)
    } else {
        // 🟢 Nhân hệ số 2.0 vào speed để nhanh gấp đôi khi di chuyển chuột
        float speed = Clamp01f(aimSpeed) * 2.0f; 
        speed = fminf(speed, 1.0f); // Giới hạn max 1.0 để đảm bảo mượt

        t = speed * speed;
        
        float centerBoost = 1.0f - Clamp01f(angle / 30.0f);
        t += centerBoost * 0.20f; 
        
        t = fmaxf(0.05f, fminf(t, 1.0f)); 
    }

    // 🟢 SỬA LỖI COMPILE: Bỏ đoạn damping phức tạp, chỉ dùng Slerp cơ bản
    Quaternion out;
    if (t >= 0.95f) {
        // Nếu gần đạt target, set thẳng để tránh rung
        out = q;
    } else {
        // Slerp mượt
        out = Quaternion::Normalized(Quaternion::Slerp(current, q, t));
    }
    
    WriteAddr<Quaternion>(player + kAimRotation,    out);
    WriteAddr<Quaternion>(player + kAimRotationAux, out);
}

//static inline uint32_t get_VisibleFlags(uint64_t player) {
   // uint64_t arr = ReadAddr<uint64_t>(player + kVisibleObj);
    //return isVaildPtr(arr) ? ReadAddr<uint32_t>(arr + kVisibleObjFlags) : 0;
//}
//bool get_IsVisible(uint64_t p)                      { return isVaildPtr(p) && (get_VisibleFlags(p) & kISVisibleDynamicPVS) != 0; }
//bool get_IsVisibleByFlag(uint64_t p, uint32_t flag) { return isVaildPtr(p) && (get_VisibleFlags(p) & flag) != 0; }
//bool get_IsFPPVisible(uint64_t p)                   { return isVaildPtr(p) && (get_VisibleFlags(p) & kISVisibleFPPMask) == kISVisibleFPPMask; }
bool get_IsFiring(uint64_t p)   { return isVaildPtr(p) && GetDataUInt16(p, 21) == 2; }
bool get_IsScoping(uint64_t p)  { return isVaildPtr(p) && GetDataUInt16(p, 12) != 0; }

// ─── Main ESP Render ──────────────────────────
- (ESPFrameStats)renderESPWithBuffers:(ESPGeometryBuffers *)buffers
                            viewWidth:(CGFloat)vw viewHeight:(CGFloat)vh
                        matrixVpWidth:(CGFloat)vpW matrixVpHeight:(CGFloat)vpH {

    ESPFrameStats stats = {0, 0, false};
    if (!buffers || Moudule_Base == -1 || IsAtLobby(Moudule_Base)) return stats;

    cacheRefreshTick++;
    if (cacheRefreshTick > 30 ||
        !isVaildPtr(cachedMatchGame) || !isVaildPtr(cachedMatch) || !isVaildPtr(cachedCamera)) {
        cachedMatchGame = getMatchGame(Moudule_Base);
        if (!isVaildPtr(cachedMatchGame)) return stats;
        cachedCamera     = CameraMain(cachedMatchGame);
        cachedMatch      = getMatch(cachedMatchGame);
        cacheRefreshTick = 0;
    }
    if (!isVaildPtr(cachedCamera) || !isVaildPtr(cachedMatch)) return stats;

if(BackJump) {

//BackJUMP(cachedMatchGame);

}

    uint64_t myPawn = getLocalPlayer(cachedMatch);
    if (!isVaildPtr(myPawn) || get_CurHP(myPawn) <= 0) return stats;

    stats.inMatch = true;

        if (camcao) { 
        uint64_t FollowCameraObj = ReadAddr<uint64_t>(myPawn + kFollowCamera);
        if (isVaildPtr(FollowCameraObj)) {
            float currentCamVal = ReadAddr<float>(FollowCameraObj + kFOVOffset);
            if (currentCamVal != Campc) {
                WriteAddr<float>(FollowCameraObj + kFOVOffset, Campc);
            }
            s_lastFollowCameraObj = FollowCameraObj;
        }
    } else if (s_lastFollowCameraObj != 0) {
        if (isVaildPtr(s_lastFollowCameraObj)) {
            WriteAddr<float>(s_lastFollowCameraObj + kFOVOffset, 1.0f);
        }
        s_lastFollowCameraObj = 0;
    }


    // ========== THÊM MỚI: 3 chức năng Memory (NoReload, VohaDan, FastFire) ==========
    /*
    uint64_t playerAttributes = ReadAddr<uint64_t>(myPawn + kPlayerAttributes);
    if (isVaildPtr(playerAttributes)) {
        WriteAddr<bool>(playerAttributes + kShootNoReload, isNoReload);
}
        
        // Fast Fire Toggle
        
        if (isFastFire) {
            WriteAddr<float>(playerAttributes + 0x270, 0.2f);
        } else {
            WriteAddr<float>(playerAttributes + 0x270, 1.0f);
        }
    }
    
    uint64_t weaponHand = WeaponOnHand(myPawn);
    if (isVaildPtr(weaponHand)) {
        WriteAddr<bool>(weaponHand + kWeaponCostAmmo, !isVohaDan);
    }
    */    
    // =================================================================================

    uint64_t camTransform = ReadAddr<uint64_t>(myPawn + kMainCameraTransform);
    if (!isVaildPtr(camTransform)) return stats;
    Vector3 myLoc = getPositionExt(camTransform);

    uint64_t playerDict = ReadAddr<uint64_t>(cachedMatch + kMatchPlayerDict);
    if (!isVaildPtr(playerDict)) return stats;

    int      dictCount  = ReadAddr<int>(playerDict + kDictCount);
    uint64_t entriesArr = ReadAddr<uint64_t>(playerDict + kDictEntries);
    if (!isVaildPtr(entriesArr)) return stats;

    int slotCap = ReadAddr<int>(entriesArr + kIl2CppArrayMaxLength);
    if (slotCap <= 0 || slotCap > 256 || dictCount <= 0) return stats;

    float *matrix = GetViewMatrix(cachedCamera);
    if (!matrix) return stats;

    CGFloat screenVpW = vpW > 1.0 ? vpW : vw;
    CGFloat screenVpH = vpH > 1.0 ? vpH : vh;
    CGPoint center    = CGPointMake(vw / 2.0f, vh / 2.0f);
    
    CGPoint topCenter = CGPointMake(vw / 2.0f, 0.0f);

    uint64_t bestTarget   = 0;
    Vector3  bestHeadPos;
    float    bestScore    = FLT_MAX;
    float    bestDistance = FLT_MAX;

    const float aimFovSq  = (isAimbot || aimsilent1) ? aimFov * aimFov : 0.0f;
    const float safeDist  = fmaxf(aimDistance, 1.0f);
    const float safeFovSq = fmaxf(aimFovSq, 1.0f);
    const uint64_t base   = entriesArr + kIl2CppArrayItems;

    for (int i = 0; i < slotCap; i++) {
        uint64_t ent = base + (uint64_t)kDictEntryStrideBytePlayer * (uint64_t)i;
        if (ReadAddr<int>(ent) == 0) continue;

        uint64_t pawn = ReadAddr<uint64_t>(ent + (uint64_t)kDictEntryValueOffByte);
        if (!isVaildPtr(pawn) || isLocalTeamMate(myPawn, pawn)) continue;

        int hp = get_CurHP(pawn);
        if (hp <= 0) continue;

        Vector3 footPos = getPositionExt(getHip(pawn));
        if (IsZeroVec(footPos)) continue;

        float dis = Vector3::Distance(myLoc, footPos);
        if (dis > 400.0f) continue;

        Vector3 headPos  = getPositionExt(getHead(pawn));

Vector3 aimPos = headPos;
        bool    isBot    = get_IsBot(pawn);

        bool    isKnocked = get_IsKnockedDown(pawn);
        
        bool aimVis = getIsVisible(pawn);

        bool    espVis   = aimVis || isKnocked;

        if ((isAimbot || aimsilent1) && dis <= aimDistance) {
            BOOL valid = YES;
            if (isAimIgnoreBot    && isBot)      valid = NO;
            if (isAimIgnoreKnock  && isKnocked)  valid = NO;
            if (!isAimCheckVisible && !aimVis)    valid = NO;

            if (valid) {
                Vector3 w2s = WorldToScreenLayer(aimPos, matrix,
                                                 (float)screenVpW, (float)screenVpH,
                                                 (float)vw, (float)vh);
                if (w2s.z > 0.001f) {
                    float dx = w2s.x - center.x;
                    float dy = w2s.y - center.y;
                    float dSq = dx * dx + dy * dy;

                    // Silent: выбираем лучшую цель без ограничения FOV
                    // Aimbot: только в пределах FOV
                    bool inFov = (dSq <= aimFovSq);
                    if (inFov || (aimsilent1 && !isAimbot)) {
                        float cn = inFov ? dSq / safeFovSq : 1.0f;
                        float dn = dis  / safeDist;
                        float score;

                        if (aimTargetMode == 0)
                            score = cn * 0.85f + dn * 0.15f;
                        else if (aimTargetMode == 1)
                            score = fminf((float)hp / 200.0f, 1.5f) * 0.65f
                                    + cn * 0.25f + dn * 0.10f;
                        else
                            score = dn * 0.75f + cn * 0.25f;

                        if (pawn == gAimLockTarget) score *= 0.80f;

                        if (score < bestScore) {
                            bestScore    = score;
                            bestDistance = dis;
                            bestTarget   = pawn;
                            bestHeadPos  = aimPos;
                        }
                    }
                }
            }
        }

        if (espVis) {

if (isBot)
    stats.botCount++;
else
    stats.playerCount++;

            RenderESPForPawn(buffers,
                             ESPTextCallback,
                             (__bridge void *)self,
                             pawn, hp, dis, matrix,
                             (float)vw, (float)vh,
                             (float)screenVpW, (float)screenVpH);
        }
    }

    if (!isAimbot) {
        gAimLockTarget = gAimLockLostFrames = 0;
    } else if (bestTarget) {
        gAimLockTarget     = bestTarget;
        gAimLockLostFrames = 0;
    } else if (gAimLockTarget) {
        if (++gAimLockLostFrames > kAimLockMaxLostFrames)
            gAimLockTarget = gAimLockLostFrames = 0;
    }

    if (isAimbot && bestTarget) {
        bool fire  = get_IsFiring(myPawn);
        bool scope = get_IsScoping(myPawn);
        bool go    = true;

        switch (triggerMode) {
            case 1: go = fire;         break;
            case 2: go = scope;        break;
            case 3: go = fire || scope; break;
            default: break;
        }

        if (go && bestDistance >= 0.2f) {
            float yBias = (aimPosition == 0) ? 0.1f : (aimPosition == 1 ? -0.06f : -0.15f);
            set_aim(myPawn, GetRotationToLocation(bestHeadPos, yBias, myLoc), bestDistance);
            if (triggerMode == 1 || (triggerMode == 3 && fire))
                SetDataUInt16(myPawn, 21, 2);
        }
    }

    // ─── Silent Aim: update shared target + tick ─────────────────────
    g_SilentBestTarget = bestTarget;
    if (aimsilent1)
        RunSilentAim();
    else
        ResetSilentAim();

    return stats;
}

@end

@implementation ESPOverlayView {
    ESP_View *_espView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    for (UIView *v in self.subviews) [v removeFromSuperview];
    self.backgroundColor        = UIColor.clearColor;
    self.userInteractionEnabled = NO;

    _espView = [[ESP_View alloc] initWithFrame:self.bounds];
    _espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_espView];
    return self;
}

@end
