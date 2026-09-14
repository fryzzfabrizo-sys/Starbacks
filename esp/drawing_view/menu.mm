#import "menu.h"
#import "icons.h"
#import "ModMenuViewController.h"
#import "ESPPrefs.h"
#import "esp.h"
#import "../../mahoa.h"
#import <UIKit/UIKit.h>

static const CGFloat kMenuButtonSize = 56.0f;
static const CGFloat kAccentR = 1.0f, kAccentG = 0.35f, kAccentB = 0.2f;
static const CGFloat kAuxButtonSize = 46.0f;
static const CGFloat kAuxGap = 8.0f;

static NSString *titleForTriggerMode(int mode) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[ @"Auto", @"Fire", @"Scope", @"Fire/Scope" ]; });
    if (mode < 0 || mode >= (int)names.count) mode = 0;
    return names[(NSUInteger)mode];
}

static NSString *titleForAimPos(int aimPos) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[ @"Head", @"Neck", @"Chest" ]; });
    if (aimPos < 0 || aimPos >= (int)names.count) aimPos = 0;
    return names[(NSUInteger)aimPos];
}

@interface MenuView ()
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *aimbotButton;
@property (nonatomic, strong) UIButton *aimbotModeButton;
@property (nonatomic, strong) UIButton *aimbotTargetButton;
@property (nonatomic, assign) NSInteger trackingPointerId;
@property (nonatomic, assign) BOOL touchOnButton;
@property (nonatomic, assign) BOOL buttonDragging;
@property (nonatomic, assign) BOOL touchOnAimbotButton;
@property (nonatomic, assign) BOOL touchOnAimbotModeButton;
@property (nonatomic, assign) BOOL touchOnAimbotTargetButton;
@property (nonatomic, assign) BOOL aimbotButtonDragging;
@property (nonatomic, assign) BOOL aimbotModeButtonDragging;
@property (nonatomic, assign) BOOL aimbotTargetButtonDragging;
@property (nonatomic, assign) CGPoint buttonDragStartCenter;
@property (nonatomic, assign) CGPoint buttonDragStartPoint;
@property (nonatomic, assign) CGPoint aimbotDragStartCenter;
@property (nonatomic, assign) CGPoint aimbotDragStartPoint;
@property (nonatomic, assign) CGPoint aimbotModeDragStartCenter;
@property (nonatomic, assign) CGPoint aimbotModeDragStartPoint;
@property (nonatomic, assign) CGPoint aimbotTargetDragStartCenter;
@property (nonatomic, assign) CGPoint aimbotTargetDragStartPoint;
@property (nonatomic, strong) ModMenuViewController *presentedModMenu;
@property (nonatomic, strong) UISwitch *floatSwitch;

@property BOOL touchOnSwitch;
@property BOOL switchDragging;
@property CGPoint switchDragStartCenter;
@property CGPoint switchDragStartPoint;

@end

@implementation MenuView

- (void)layoutSubviews {
    [super layoutSubviews];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        [self setupMenuButton];
    }
    return self;
}

- (void)setupMenuButton {
    _floatSwitch = [[UISwitch alloc] init];
    _floatSwitch.transform = CGAffineTransformMakeScale(0.75f, 0.75f);
    _floatSwitch.center = CGPointMake(
        CGRectGetMaxX(_aimbotButton.frame) + 35,
        CGRectGetMidY(_aimbotButton.frame)
    );
    [_floatSwitch setOn:ESPPrefsBool(NSSENCRYPT("testGhost"), NO)];
    [_floatSwitch addTarget:self
                     action:@selector(onSwitchChanged:)
           forControlEvents:UIControlEventValueChanged];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwitchPan:)];
    [_floatSwitch addGestureRecognizer:pan];
    [self addSubview:_floatSwitch];

    _menuButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _menuButton.frame = CGRectMake(20, 100, kMenuButtonSize, kMenuButtonSize);
    _menuButton.backgroundColor = [UIColor clearColor];
    
    UIImage *icon = FloatButtonIcon();
    if (!icon) {
        if (@available(iOS 13.0, *)) {
            _menuButton.tintColor = [UIColor colorWithRed:kAccentR green:kAccentG blue:kAccentB alpha:1.0f];
            icon = [UIImage systemImageNamed:@"line.3.horizontal"];
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
            icon = [icon imageByApplyingSymbolConfiguration:cfg];
        }
    }
    
    if (icon) {
        // ✅ QUAN TRỌNG: Dùng AlwaysOriginal để giữ màu gốc của icon
        icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        [_menuButton setImage:icon forState:UIControlStateNormal];
        // ❌ KHÔNG ép màu xanh
        // _menuButton.tintColor = [UIColor colorWithRed:0.20f green:0.85f blue:0.25f alpha:1.0f];
        
        // Animation vẫn giữ nguyên nếu muốn
        //CABasicAnimation *rotationAnimation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        //rotationAnimation.toValue = [NSNumber numberWithFloat:M_PI * 2.0];
        //rotationAnimation.duration = 6.0;
        //rotationAnimation.cumulative = YES;
        //rotationAnimation.repeatCount = HUGE_VALF;
        //rotationAnimation.removedOnCompletion = NO;
        //[_menuButton.imageView.layer addAnimation:rotationAnimation forKey:@"menuButtonRotation"];

    } else {
        [_menuButton setTitle:@"M" forState:UIControlStateNormal];
        [_menuButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _menuButton.titleLabel.font = [UIFont boldSystemFontOfSize:20.0f];
    }
    [self addSubview:_menuButton];

    _aimbotButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _aimbotButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap,
                                     _menuButton.frame.origin.y,
                                     kAuxButtonSize,
                                     kAuxButtonSize);
    _aimbotButton.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.90f];
    _aimbotButton.layer.cornerRadius = kAuxButtonSize / 2.0f;
    _aimbotButton.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [_aimbotButton setTitle:@"AIM" forState:UIControlStateNormal];
    [_aimbotButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self addSubview:_aimbotButton];

    _aimbotModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _aimbotModeButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap,
                                         CGRectGetMaxY(_menuButton.frame) + kAuxGap,
                                         kAuxButtonSize,
                                         kAuxButtonSize);
    _aimbotModeButton.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.90f];
    _aimbotModeButton.layer.cornerRadius = kAuxButtonSize / 2.0f;
    _aimbotModeButton.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [_aimbotModeButton setTitle:titleForTriggerMode(0) forState:UIControlStateNormal];
    [_aimbotModeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    // [self addSubview:_aimbotModeButton]; // XOÁ HIỂN THỊ BUTTON MODE

    _aimbotTargetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _aimbotTargetButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap,
                                           CGRectGetMaxY(_aimbotModeButton.frame) + kAuxGap,
                                           kAuxButtonSize,
                                           kAuxButtonSize);
    _aimbotTargetButton.backgroundColor = [UIColor colorWithWhite:0.12f alpha:0.90f];
    _aimbotTargetButton.layer.cornerRadius = kAuxButtonSize / 2.0f;
    _aimbotTargetButton.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [_aimbotTargetButton setTitle:titleForAimPos(0) forState:UIControlStateNormal];
    [_aimbotTargetButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    // [self addSubview:_aimbotTargetButton]; // XOÁ HIỂN THỊ BUTTON TARGET

    [self loadMenuButtonPosition];
    [self refreshAimbotButtonTitles];
}

- (void)onSwitchChanged:(UISwitch *)sender {
    ESPPrefsSetBool(NSSENCRYPT("testGhost"), sender.isOn);
    ESPPrefsSync();
    ESPSyncFromPrefs();
}

- (void)reloadFloatingAuxButtonsFromPrefs {
    [self refreshAimbotButtonTitles];
}

- (void)loadMenuButtonPosition {
    CGFloat x = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingMenuBtnX"];
    CGFloat y = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingMenuBtnY"];
    if (x > 0 || y > 0) {
        _menuButton.frame = CGRectMake(x, y, kMenuButtonSize, kMenuButtonSize);
    }

    CGFloat sx = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatSwitchX"];
    CGFloat sy = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatSwitchY"];
    if (sx > 0 || sy > 0) {
        _floatSwitch.frame = CGRectMake(sx, sy, _floatSwitch.frame.size.width, _floatSwitch.frame.size.height);
    }

    CGFloat ax = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingAimBtnX"];
    CGFloat ay = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingAimBtnY"];
    if (ax > 0 || ay > 0) {
        _aimbotButton.frame = CGRectMake(ax, ay, kAuxButtonSize, kAuxButtonSize);
    } else {
        _aimbotButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap,
                                         _menuButton.frame.origin.y,
                                         kAuxButtonSize, kAuxButtonSize);
    }

    CGFloat mx = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingModeBtnX"];
    CGFloat my = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingModeBtnY"];
    if (mx > 0 || my > 0) {
        _aimbotModeButton.frame = CGRectMake(mx, my, kAuxButtonSize, kAuxButtonSize);
    } else {
        _aimbotModeButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap,
                                             CGRectGetMaxY(_menuButton.frame) + kAuxGap,
                                             kAuxButtonSize, kAuxButtonSize);
    }

    CGFloat tx = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingTargetBtnX"];
    CGFloat ty = [[NSUserDefaults standardUserDefaults] floatForKey:@"FloatingTargetBtnY"];
    if (tx > 0 || ty > 0) {
        _aimbotTargetButton.frame = CGRectMake(tx, ty, kAuxButtonSize, kAuxButtonSize);
    } else {
        _aimbotTargetButton.frame = CGRectMake(CGRectGetMaxX(_menuButton.frame) + kAuxGap,
                                               CGRectGetMaxY(_aimbotModeButton.frame) + kAuxGap,
                                               kAuxButtonSize, kAuxButtonSize);
    }
}

- (void)refreshAimbotButtonVisibility {
    BOOL showAim = ESPPrefsBool(NSSENCRYPT("FloatAimBtn"), YES);
    BOOL showghost = ESPPrefsBool(NSSENCRYPT("showghost"), YES);
    _aimbotButton.hidden = !showAim;
    _floatSwitch.hidden = YES;
    _aimbotModeButton.hidden = YES;
    _aimbotTargetButton.hidden = YES;
}

- (void)refreshAimbotButtonTitles {
    BOOL on = ESPPrefsBool(NSSENCRYPT("Aimbot"), NO);
    int mode = (int)ESPPrefsFloat(NSSENCRYPT("TriggerMode"), 0.0f);
    if (mode < 0 || mode > 3) mode = 0;
    int aimPos = (int)ESPPrefsFloat(NSSENCRYPT("AimPos"), 0.0f);
    if (aimPos < 0 || aimPos > 2) aimPos = 0;

    _aimbotButton.backgroundColor = on ? [UIColor colorWithRed:kAccentR green:kAccentG blue:kAccentB alpha:0.90f]
                                       : [UIColor colorWithWhite:0.12f alpha:0.90f];
    [_aimbotButton setTitle:(on ? @"AIM" : @"AIM") forState:UIControlStateNormal];
    [_aimbotModeButton setTitle:titleForTriggerMode(mode) forState:UIControlStateNormal];
    [_aimbotTargetButton setTitle:titleForAimPos(aimPos) forState:UIControlStateNormal];
    [self refreshAimbotButtonVisibility];
}

- (UIViewController *)viewControllerForView:(UIView *)view {
    UIResponder *r = view;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = [r nextResponder];
    return [r isKindOfClass:[UIViewController class]] ? (UIViewController *)r : nil;
}

- (void)presentModMenu {
    UIViewController *parentVC = [self viewControllerForView:self];
    if (!parentVC) return;
    ModMenuViewController *vc = [[ModMenuViewController alloc] init];
    vc.view.frame = self.bounds;
    __weak MenuView *wself = self;
    vc.onCloseBlock = ^{
        [wself dismissModMenu];
    };
    vc.onExitHUDRequested = ^{
        if (wself.onExitHUDRequested) wself.onExitHUDRequested();
    };
    _presentedModMenu = vc;
    [parentVC addChildViewController:vc];
    [self addSubview:vc.view];
    [vc didMoveToParentViewController:parentVC];
    [self bringSubviewToFront:vc.view];
}

- (void)dismissModMenu {
    if (!_presentedModMenu) return;
    ModMenuViewController *vc = _presentedModMenu;
    _presentedModMenu = nil;
    [vc willMoveToParentViewController:nil];
    [vc.view removeFromSuperview];
    [vc removeFromParentViewController];
    [self reloadFloatingAuxButtonsFromPrefs];
}

- (void)showMenu {
    if (_presentedModMenu) return;
    [self presentModMenu];
}

- (void)hideMenu {
    if (_presentedModMenu) {
        [self dismissModMenu];
        return;
    }
}

- (BOOL)handleTouchAtWindowPoint:(CGPoint)windowPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    CGPoint local = [self convertPoint:windowPoint fromView:self.window];
    const CGFloat kInset = 12.0f;
    CGRect btnHit = CGRectInset(_menuButton.frame, -kInset, -kInset);
    BOOL insideBtn = CGRectContainsPoint(btnHit, local);
    BOOL insideAim = NO;
    BOOL insideMode = NO;
    BOOL insideTarget = NO;
    BOOL insideSwitch = CGRectContainsPoint(CGRectInset(_floatSwitch.frame, -12, -12), local);

    if (!_aimbotButton.hidden) {
        CGRect aimHit = CGRectInset(_aimbotButton.frame, -kInset, -kInset);
        insideAim = CGRectContainsPoint(aimHit, local);
    }
    if (!_aimbotModeButton.hidden) {
        CGRect modeHit = CGRectInset(_aimbotModeButton.frame, -kInset, -kInset);
        insideMode = CGRectContainsPoint(modeHit, local);
    }
    if (!_aimbotTargetButton.hidden) {
        CGRect targetHit = CGRectInset(_aimbotTargetButton.frame, -kInset, -kInset);
        insideTarget = CGRectContainsPoint(targetHit, local);
    }

    if (_presentedModMenu) {
        CGPoint inMenuView = [self convertPoint:local toView:_presentedModMenu.view];
        if ([_presentedModMenu handleTouchAtViewPoint:inMenuView phase:(NSInteger)phase pointerId:pointerId])
            return YES;
        if (!insideBtn && !insideAim && !insideMode && !insideTarget) {
            if (phase == UITouchPhaseBegan) [self dismissModMenu];
            return YES;
        }
    }

    switch (phase) {
        case UITouchPhaseBegan: {
            if (insideSwitch) {
                _touchOnSwitch = YES;
                _switchDragging = NO;
                _switchDragStartCenter = _floatSwitch.center;
                _switchDragStartPoint = local;
                _trackingPointerId = pointerId;
                return YES;
            }
            if (insideAim && !_touchOnAimbotButton) {
                _touchOnAimbotButton = YES;
                _trackingPointerId = pointerId;
                _aimbotButtonDragging = NO;
                _aimbotDragStartCenter = _aimbotButton.center;
                _aimbotDragStartPoint = local;
                return YES;
            }
            if (insideMode && !_touchOnAimbotModeButton) {
                _touchOnAimbotModeButton = YES;
                _trackingPointerId = pointerId;
                _aimbotModeButtonDragging = NO;
                _aimbotModeDragStartCenter = _aimbotModeButton.center;
                _aimbotModeDragStartPoint = local;
                return YES;
            }
            if (insideTarget && !_touchOnAimbotTargetButton) {
                _touchOnAimbotTargetButton = YES;
                _trackingPointerId = pointerId;
                _aimbotTargetButtonDragging = NO;
                _aimbotTargetDragStartCenter = _aimbotTargetButton.center;
                _aimbotTargetDragStartPoint = local;
                return YES;
            }
            if (insideBtn && !_touchOnButton) {
                _touchOnButton = YES;
                _buttonDragging = NO;
                _trackingPointerId = pointerId;
                _buttonDragStartCenter = _menuButton.center;
                _buttonDragStartPoint = local;
                return YES;
            }
            return NO;
        }
        case UITouchPhaseMoved: {
            if (_touchOnSwitch && pointerId == _trackingPointerId) {
                CGFloat dx = local.x - _switchDragStartPoint.x;
                CGFloat dy = local.y - _switchDragStartPoint.y;
                if (!_switchDragging && fabs(dx)+fabs(dy) > 12) {
                    _switchDragging = YES;
                }
                if (_switchDragging) {
                    _floatSwitch.center = CGPointMake(_switchDragStartCenter.x + dx, _switchDragStartCenter.y + dy);
                    _switchDragStartCenter = _floatSwitch.center;
                    _switchDragStartPoint = local;
                }
                return YES;
            }
            if (_touchOnButton && pointerId == _trackingPointerId) {
                const CGFloat kDragThreshold = 12.0f;
                CGFloat dx = local.x - _buttonDragStartPoint.x;
                CGFloat dy = local.y - _buttonDragStartPoint.y;
                if (!_buttonDragging && (fabs(dx) + fabs(dy) > kDragThreshold)) {
                    _buttonDragging = YES;
                }
                if (_buttonDragging) {
                    _menuButton.center = CGPointMake(_buttonDragStartCenter.x + dx, _buttonDragStartCenter.y + dy);
                    _buttonDragStartCenter = _menuButton.center;
                    _buttonDragStartPoint = local;
                }
                return YES;
            }
            if (_touchOnAimbotButton && pointerId == _trackingPointerId) {
                const CGFloat kDragThreshold = 12.0f;
                CGFloat dx = local.x - _aimbotDragStartPoint.x;
                CGFloat dy = local.y - _aimbotDragStartPoint.y;
                if (!_aimbotButtonDragging && (fabs(dx) + fabs(dy) > kDragThreshold)) {
                    _aimbotButtonDragging = YES;
                }
                if (_aimbotButtonDragging) {
                    _aimbotButton.center = CGPointMake(_aimbotDragStartCenter.x + dx, _aimbotDragStartCenter.y + dy);
                    _aimbotDragStartCenter = _aimbotButton.center;
                    _aimbotDragStartPoint = local;
                }
                return YES;
            }
            if (_touchOnAimbotModeButton && pointerId == _trackingPointerId) {
                const CGFloat kDragThreshold = 12.0f;
                CGFloat dx = local.x - _aimbotModeDragStartPoint.x;
                CGFloat dy = local.y - _aimbotModeDragStartPoint.y;
                if (!_aimbotModeButtonDragging && (fabs(dx) + fabs(dy) > kDragThreshold)) {
                    _aimbotModeButtonDragging = YES;
                }
                if (_aimbotModeButtonDragging) {
                    _aimbotModeButton.center = CGPointMake(_aimbotModeDragStartCenter.x + dx, _aimbotModeDragStartCenter.y + dy);
                    _aimbotModeDragStartCenter = _aimbotModeButton.center;
                    _aimbotModeDragStartPoint = local;
                }
                return YES;
            }
            if (_touchOnAimbotTargetButton && pointerId == _trackingPointerId) {
                const CGFloat kDragThreshold = 12.0f;
                CGFloat dx = local.x - _aimbotTargetDragStartPoint.x;
                CGFloat dy = local.y - _aimbotTargetDragStartPoint.y;
                if (!_aimbotTargetButtonDragging && (fabs(dx) + fabs(dy) > kDragThreshold)) {
                    _aimbotTargetButtonDragging = YES;
                }
                if (_aimbotTargetButtonDragging) {
                    _aimbotTargetButton.center = CGPointMake(_aimbotTargetDragStartCenter.x + dx, _aimbotTargetDragStartCenter.y + dy);
                    _aimbotTargetDragStartCenter = _aimbotTargetButton.center;
                    _aimbotTargetDragStartPoint = local;
                }
                return YES;
            }
            return _touchOnButton || _touchOnAimbotButton || _touchOnAimbotModeButton || _touchOnAimbotTargetButton;
        }
        case UITouchPhaseEnded:
        case UITouchPhaseCancelled: {
            if (_touchOnSwitch && pointerId == _trackingPointerId) {
                _touchOnSwitch = NO;
                if (_switchDragging) {
                    // lưu vị trí
                } else {
                    [_floatSwitch setOn:!_floatSwitch.isOn animated:YES];
                    [_floatSwitch sendActionsForControlEvents:UIControlEventValueChanged];
                    ESPPrefsSetBool(NSSENCRYPT("testGhost"), _floatSwitch.isOn);
                    ESPPrefsSync();
                }
                _switchDragging = NO;
                return YES;
            }
            if (_touchOnAimbotButton && pointerId == _trackingPointerId) {
                _touchOnAimbotButton = NO;
                _trackingPointerId = -1;
                if (_aimbotButtonDragging) {
                    [[NSUserDefaults standardUserDefaults] setFloat:_aimbotButton.frame.origin.x forKey:@"FloatingAimBtnX"];
                    [[NSUserDefaults standardUserDefaults] setFloat:_aimbotButton.frame.origin.y forKey:@"FloatingAimBtnY"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                } else {
                    BOOL on = ESPPrefsBool(NSSENCRYPT("Aimbot"), NO);
                    ESPPrefsSetBool(NSSENCRYPT("Aimbot"), !on);
                    ESPPrefsSync();
                    ESPSyncFromPrefs();
                    [self refreshAimbotButtonTitles];
                }
                _aimbotButtonDragging = NO;
                return YES;
            }
            if (_touchOnAimbotModeButton && pointerId == _trackingPointerId) {
                _touchOnAimbotModeButton = NO;
                _trackingPointerId = -1;
                if (_aimbotModeButtonDragging) {
                    [[NSUserDefaults standardUserDefaults] setFloat:_aimbotModeButton.frame.origin.x forKey:@"FloatingModeBtnX"];
                    [[NSUserDefaults standardUserDefaults] setFloat:_aimbotModeButton.frame.origin.y forKey:@"FloatingModeBtnY"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                } else {
                    int mode = (int)ESPPrefsFloat(NSSENCRYPT("TriggerMode"), 0.0f);
                    mode = (mode + 1) % 4;
                    ESPPrefsSetFloat(NSSENCRYPT("TriggerMode"), (float)mode);
                    ESPPrefsSync();
                    ESPSyncFromPrefs();
                    [self refreshAimbotButtonTitles];
                }
                _aimbotModeButtonDragging = NO;
                return YES;
            }
            if (_touchOnAimbotTargetButton && pointerId == _trackingPointerId) {
                _touchOnAimbotTargetButton = NO;
                _trackingPointerId = -1;
                if (_aimbotTargetButtonDragging) {
                    [[NSUserDefaults standardUserDefaults] setFloat:_aimbotTargetButton.frame.origin.x forKey:@"FloatingTargetBtnX"];
                    [[NSUserDefaults standardUserDefaults] setFloat:_aimbotTargetButton.frame.origin.y forKey:@"FloatingTargetBtnY"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                } else {
                    int ap = (int)ESPPrefsFloat(NSSENCRYPT("AimPos"), 0.0f);
                    if (ap < 0 || ap > 2) ap = 0;
                    ap = (ap + 1) % 3;
                    ESPPrefsSetFloat(NSSENCRYPT("AimPos"), (float)ap);
                    ESPPrefsSync();
                    ESPSyncFromPrefs();
                    [self refreshAimbotButtonTitles];
                }
                _aimbotTargetButtonDragging = NO;
                return YES;
            }
            if (_touchOnButton && pointerId == _trackingPointerId) {
                BOOL wasDrag = _buttonDragging;
                _touchOnButton = NO;
                _buttonDragging = NO;
                _trackingPointerId = -1;
                if (!wasDrag) [self togglePanel];
                [[NSUserDefaults standardUserDefaults] setFloat:(float)_menuButton.frame.origin.x forKey:@"FloatingMenuBtnX"];
                [[NSUserDefaults standardUserDefaults] setFloat:(float)_menuButton.frame.origin.y forKey:@"FloatingMenuBtnY"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return YES;
            }
            return NO;
        }
        default:
            return NO;
    }
}

- (BOOL)handleTouchAtLocalPoint:(CGPoint)localPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    return [self handleTouchAtWindowPoint:[self convertPoint:localPoint toView:self.window] phase:phase pointerId:pointerId];
}

- (void)togglePanel {
    if (_presentedModMenu) {
        [self dismissModMenu];
        return;
    }
    [self presentModMenu];
}

@end