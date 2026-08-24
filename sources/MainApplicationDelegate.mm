#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "HomeViewController.h"
#import "InfoViewController.h"
#import "roothide/varCleanController.h"

#import "HUDHelper.h"

@implementation MainApplicationDelegate {
    HomeViewController *_homeViewController;
}

- (instancetype)init {
    self = [super init];
    if (self) {

    }
    return self;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions {

    // FIX WINDOW
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    // ROOT VCs
    _homeViewController = [[HomeViewController alloc] init];
    InfoViewController *infoVC = [[InfoViewController alloc] init];
    varCleanController *varVC = [varCleanController sharedInstance];

    // NAVIGATION
    UINavigationController *homeNav =
    [[UINavigationController alloc] initWithRootViewController:_homeViewController];

    UINavigationController *infoNav =
    [[UINavigationController alloc] initWithRootViewController:infoVC];

    UINavigationController *varNav =
    [[UINavigationController alloc] initWithRootViewController:varVC];

    // NAV BAR
    homeNav.navigationBarHidden = YES;
    infoNav.navigationBarHidden = YES;
    varNav.navigationBarHidden  = NO;

    // IMPORTANT FIX
    homeNav.view.userInteractionEnabled = YES;
    infoNav.view.userInteractionEnabled = YES;
    varNav.view.userInteractionEnabled  = YES;

    // TAB ICONS
    if (@available(iOS 13.0, *)) {

        homeNav.tabBarItem =
        [[UITabBarItem alloc]
         initWithTitle:@"Home"
         image:[UIImage systemImageNamed:@"house.fill"]
         tag:0];

        infoNav.tabBarItem =
        [[UITabBarItem alloc]
         initWithTitle:@"Info"
         image:[UIImage systemImageNamed:@"info.circle.fill"]
         tag:1];

        varNav.tabBarItem =
        [[UITabBarItem alloc]
         initWithTitle:@"VarClean"
         image:[UIImage systemImageNamed:@"trash.fill"]
         tag:2];

    } else {

        homeNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"Home"
                                      image:nil
                                        tag:0];

        infoNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"Info"
                                      image:nil
                                        tag:1];

        varNav.tabBarItem =
        [[UITabBarItem alloc] initWithTitle:@"VarClean"
                                      image:nil
                                        tag:2];
    }

    // TAB BAR
    UITabBarController *tab = [[UITabBarController alloc] init];

    tab.viewControllers = @[
        homeNav,
        infoNav,
        varNav
    ];

    tab.selectedIndex = 0;

    // FIX TOUCH
    tab.view.userInteractionEnabled = YES;
    tab.tabBar.userInteractionEnabled = YES;

    // STYLE
    tab.tabBar.barStyle = UIBarStyleBlack;
    tab.tabBar.translucent = NO;
    tab.tabBar.tintColor = UIColor.whiteColor;
    tab.tabBar.backgroundColor = UIColor.blackColor;

    // ROOT
    self.window.rootViewController = tab;

    // IMPORTANT
    [self.window makeKeyAndVisible];

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. Đồng bộ dữ liệu lần cuối trước khi refresh
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // 2. Chỉ refresh nếu homeViewController tồn tại
        if (self->_homeViewController) {
            [self->_homeViewController refreshHUDState];
        }

        self.window.userInteractionEnabled = YES;
    });
}

@end