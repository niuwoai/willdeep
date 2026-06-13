//
//  AIPipeConfig.m
//  AIPipe
//
//  Created by AIPipe Team
//

#import "AIPipeConfig.h"

#if TARGET_OS_MAC && !TARGET_OS_IPHONE
    // macOS
    #define DEFAULT_PLATFORM @"macos"
#else
    // iOS
    #define DEFAULT_PLATFORM @"ios"
#endif

@implementation AIPipeConfig

+ (instancetype)defaultConfig {
    AIPipeConfig *config = [[AIPipeConfig alloc] init];
    config.source = DEFAULT_PLATFORM;
    config.format = DEFAULT_PLATFORM;
    config.batchSize = 10;
    config.batchTimeoutMs = 5000;
    config.maxRetries = 3;
    config.enabled = YES;
    return config;
}

@end

