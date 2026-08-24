#import <UIKit/UIKit.h>

@interface ModMenuViewController : UIViewController
@property (nonatomic, copy) void (^onCloseBlock)(void);
@property (nonatomic, copy) void (^onExitHUDRequested)(void);
- (BOOL)handleTouchAtViewPoint:(CGPoint)point phase:(NSInteger)phase pointerId:(NSInteger)pointerId;
@end
