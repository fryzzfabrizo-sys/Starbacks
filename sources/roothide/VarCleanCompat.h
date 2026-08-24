
#import <Foundation/Foundation.h>

#ifndef Localized
#define Localized(x) (x)
#endif

static inline NSString *jbroot(NSString *path) { return path; }

#ifdef __cplusplus
extern "C" {
#endif

BOOL RootUserRemoveItemAtPath(NSString *path);
BOOL RootUserGetDirectoryContents(NSString *path, NSString *cacheFile);
void EnsureVarCleanRulesInstalled(void);

#ifdef __cplusplus
}
#endif
