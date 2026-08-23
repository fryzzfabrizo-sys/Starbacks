
#import "IOHIDEvent+KIF.h"
#import "UITouch+Private.h"
#import <UIKit/UIKit.h>

@interface UITouch (KIFAdditions)

- (instancetype)initAtPoint:(CGPoint)point
                   inWindow:(UIWindow *)window
                     onView:(UIView *)view;
- (instancetype)initTouch;

- (void)setLocationInWindow:(CGPoint)location;
- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase;

@end
