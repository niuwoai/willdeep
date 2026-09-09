#import <Foundation/Foundation.h>
#import "AIPipe.h"

static NSUInteger calls = 0;
static void previousHandler(NSException *exception) {
    calls += 1;
}

int main(void) {
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&previousHandler);
        AIPipeConfig *config = [AIPipeConfig defaultConfig];
        config.enabled = NO;
        [AIPipe initializeWithConfig:config];
        [AIPipe initializeWithConfig:config];
        NSUncaughtExceptionHandler *installed = NSGetUncaughtExceptionHandler();
        if (!installed || installed == &previousHandler) return 1;
        installed([NSException exceptionWithName:@"Fixture" reason:@"No network or user data" userInfo:nil]);
        if (calls != 1) return 2;
        NSSetUncaughtExceptionHandler(NULL);
        [AIPipe initializeWithConfig:config];
        NSGetUncaughtExceptionHandler()([NSException exceptionWithName:@"NoPreviousHandler" reason:nil userInfo:nil]);
        return calls == 1 ? 0 : 3;
    }
}
