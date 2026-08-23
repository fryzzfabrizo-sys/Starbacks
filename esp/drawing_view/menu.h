#import <UIKit/UIKit.h>

@interface MenuView : UIView
- (instancetype)initWithFrame:(CGRect)frame;
- (void)showMenu;
- (void)hideMenu;

- (BOOL)handleTouchAtWindowPoint:(CGPoint)windowPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId;

- (BOOL)handleTouchAtLocalPoint:(CGPoint)localPoint phase:(UITouchPhase)phase pointerId:(NSInteger)pointerId;

@property (nonatomic, copy) void (^onExitHUDRequested)(void);

- (void)reloadFloatingAuxButtonsFromPrefs;
@end
