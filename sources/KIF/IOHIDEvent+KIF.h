
#import <Foundation/Foundation.h>
#import "IOKit+SPI.h"

typedef struct __IOHIDEvent * IOHIDEventRef;
IOHIDEventRef kif_IOHIDEventWithTouches(NSArray *touches) CF_RETURNS_RETAINED;
