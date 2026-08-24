#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "HUDMainApplicationDelegate.h"
#import "HUDMainWindow.h"

#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"

#import "../esp/drawing_view/esp.h"
#import "../esp/drawing_view/menu.h"
#import "../esp/Core/pid.h"
#import "HUDHelper.h"
#import "UIView+SecureView.h"
#import "silent.h"

@interface HUDLandscapeContainerViewController : UIViewController
@end

@implementation HUDLandscapeContainerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = YES; // Kích hoạt tương tác cho container gốc
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
}

@end

static __weak HUDMainApplicationDelegate *_sharedHUDDelegate = nil;

BOOL HUDFloatButtonHandleTouch(CGPoint screenPoint, UITouchPhase phase, NSInteger pointerId) {
    HUDMainApplicationDelegate *d = _sharedHUDDelegate;
    if (!d) return NO;
    return [d handleTouchAtScreenPoint:screenPoint phase:phase pointerId:pointerId];
}

#pragma mark - HUDMainApplicationDelegate

@implementation HUDMainApplicationDelegate {
    SBSAccessibilityWindowHostingController *_windowHostingController;
    dispatch_source_t _gameCheckTimer;
    MenuView *_menuView;
}

- (instancetype)init
{
    if (self = [super init]) {}
    return self;
}

// Chuẩn hóa chuyển đổi tọa độ khi Window bị xoay (CGAffineTransform)
- (CGPoint)windowLocalPointFromScreen:(CGPoint)sp {
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGPoint center = CGPointMake(bounds.size.width / 2.0f, bounds.size.height / 2.0f);
    
    // Tịnh tiến về tâm
    CGPoint r = CGPointMake(sp.x - center.x, sp.y - center.y);
    
    // Đảo ngược ma trận xoay của Window để lấy tọa độ phẳng chuẩn
    CGPoint l = CGPointApplyAffineTransform(r, CGAffineTransformInvert(self.window.transform));
    
    // Đưa về góc trái trên hệ tọa độ mới của Window
    l.x += self.window.bounds.size.width / 2.0f;
    l.y += self.window.bounds.size.height / 2.0f;
    return l;
}

- (BOOL)handleTouchAtScreenPoint:(CGPoint)screenPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId {
    if (!_menuView || !self.window) return NO;
    
    CGPoint inWindow;
    // Kiểm tra xem Window có đang bị áp ma trận xoay (Transform) hay không
    if (CGAffineTransformIsIdentity(self.window.transform)) {
        inWindow = [self.window convertPoint:screenPoint fromCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
    } else {
        inWindow = [self windowLocalPointFromScreen:screenPoint];
    }
    
    // Gửi tọa độ chuẩn xác đã fix góc nghiêng vào Menu view xử lý tiếp
    BOOL consumed = [_menuView handleTouchAtWindowPoint:inWindow phase:phase pointerId:pointerId];
    return consumed;
}

- (UIInterfaceOrientation)currentInterfaceOrientation {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.activationState == UISceneActivationStateForegroundActive ||
                    ws.activationState == UISceneActivationStateForegroundInactive) {
                    return ws.interfaceOrientation;
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIInterfaceOrientation sb = [UIApplication sharedApplication].statusBarOrientation;
#pragma clang diagnostic pop
    if (sb != UIInterfaceOrientationUnknown) {
        return sb;
    }

    UIDeviceOrientation dev = [UIDevice currentDevice].orientation;
    if (UIDeviceOrientationIsLandscape(dev)) {
        return (dev == UIDeviceOrientationLandscapeLeft) ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationLandscapeLeft;
    }
    return UIInterfaceOrientationLandscapeRight;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    HUDLandscapeContainerViewController *container = [[HUDLandscapeContainerViewController alloc] init];

    // Cấu hình ESP View vẽ khung
    ESP_View *espView = [[ESP_View alloc] initWithFrame:CGRectZero];
    espView.translatesAutoresizingMaskIntoConstraints = NO;
    espView.backgroundColor = [UIColor clearColor];
    espView.userInteractionEnabled = NO; // ESP không nhận touch để tránh chặn game
    [espView hideViewFromCapture:NO];

    UIView *containerView = container.view;
    [containerView addSubview:espView];

    // Cấu hình Menu View
    MenuView *menuView = [[MenuView alloc] initWithFrame:CGRectZero];
    menuView.translatesAutoresizingMaskIntoConstraints = NO;
    menuView.userInteractionEnabled = YES; // Kích hoạt tương tác chuẩn
    
    __weak __typeof__(self) wself = self;
    menuView.onExitHUDRequested = ^{
        RequestExitHUD();
        (void)wself;
    };
    [containerView addSubview:menuView];
    _menuView = menuView;
    _sharedHUDDelegate = self;

    // ─── Silent Aim: khởi động background thread ──────────────────
    InitSilentAimThread();

    // Auto Layout căn đều toàn màn hình cho cả ESP và Menu
    [NSLayoutConstraint activateConstraints:@[
        [espView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
        [espView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
        [espView.topAnchor constraintEqualToAnchor:containerView.topAnchor],
        [espView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor],
        [menuView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
        [menuView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
        [menuView.topAnchor constraintEqualToAnchor:containerView.topAnchor],
        [menuView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor]
    ]];

    self.window = [[HUDMainWindow alloc] initWithFrame:CGRectZero];
    [self.window setRootViewController:container];

    // Tính toán kích thước theo hướng Landscape thực tế
    UIInterfaceOrientation curOrientation = [self currentInterfaceOrientation];
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    
    // Đảm bảo chiều Rộng luôn lớn hơn chiều Cao khi ở chế độ Ngang
    if (UIInterfaceOrientationIsLandscape(curOrientation)) {
        CGFloat maxDim = MAX(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
        CGFloat minDim = MIN(CGRectGetWidth(screenBounds), CGRectGetHeight(screenBounds));
        screenBounds = CGRectMake(0, 0, maxDim, minDim);
    }

    [self.window setFrame:screenBounds];
    self.window.center = CGPointMake(screenBounds.size.width / 2.0f, screenBounds.size.height / 2.0f);

    // Ép Window nhận hướng giao diện thông qua hàm ẩn hệ thống
    SEL setOrientSel = NSSelectorFromString(@"_setInterfaceOrientation:");
    if ([self.window respondsToSelector:setOrientSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSMethodSignature *sig = [self.window methodSignatureForSelector:setOrientSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:setOrientSel];
            [inv setTarget:self.window];
            NSInteger orientVal = (NSInteger)curOrientation;
            [inv setArgument:&orientVal atIndex:2];
            [inv invoke];
        }
#pragma clang diagnostic pop
    }

    // Áp dụng góc xoay Transform phù hợp để vẽ đè chuẩn lên game Landscape
    if (UIInterfaceOrientationIsLandscape(curOrientation)) {
        CGAffineTransform rot = (curOrientation == UIInterfaceOrientationLandscapeLeft)
            ? CGAffineTransformMakeRotation(-M_PI_2)
            : CGAffineTransformMakeRotation(M_PI_2);

        self.window.transform = rot;
    } else {
        self.window.transform = CGAffineTransformIdentity;
    }
    
    self.window.bounds = CGRectMake(0, 0, screenBounds.size.width, screenBounds.size.height);
    self.window.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    [containerView setNeedsLayout];
    [containerView layoutIfNeeded];

    espView.frame = containerView.bounds;
    menuView.frame = containerView.bounds;

    // Đăng ký Context ID đè hệ thống (SBSAccessibility)
    _windowHostingController = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init];
    unsigned int _contextId = [self.window _contextId];
    double windowLevel = [self.window windowLevel];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:_windowHostingController];
    [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [invocation setArgument:&_contextId atIndex:2];
    [invocation setArgument:&windowLevel atIndex:3];
    [invocation invoke];
#pragma clang diagnostic pop

    // Vòng lặp kiểm tra tiến trình Game (Tự động tắt HUD khi game đóng)
    static const char *kGameProcessName = "FreeFire";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (GetGameProcesspid((char *)kGameProcessName) == -1) {
            exit(0);
        }
    });
    
    _gameCheckTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (_gameCheckTimer) {
        dispatch_source_set_timer(_gameCheckTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), (uint64_t)(8 * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
        __weak __typeof__(self) wself = self;
        dispatch_source_set_event_handler(_gameCheckTimer, ^{
            if (GetGameProcesspid((char *)kGameProcessName) == -1) {
                __strong __typeof__(wself) sself = wself;
                if (sself && sself->_gameCheckTimer) dispatch_source_cancel(sself->_gameCheckTimer);
                exit(0);
            }
        });
        dispatch_resume(_gameCheckTimer);
    }

    return YES;
}

@end
