//
//  AIPipeConfig.h
//  AIPipe
//
//  Created by AIPipe Team
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * AIPipe SDK 配置类
 */
@interface AIPipeConfig : NSObject

/// API 密钥（必需）
@property (nonatomic, strong) NSString *apiKey;

/// API 端点 URL（必需，例如：https://api.example.com/api/v1）
@property (nonatomic, strong) NSString *endpoint;

/// 来源标识（默认：ios）
@property (nonatomic, strong) NSString *source;

/// 日志格式（默认：ios）
@property (nonatomic, strong) NSString *format;

/// 日志主题（可选）
@property (nonatomic, strong, nullable) NSString *topic;

/// 批量大小（默认：10）
@property (nonatomic, assign) NSUInteger batchSize;

/// 批量超时时间（毫秒，默认：5000）
@property (nonatomic, assign) NSTimeInterval batchTimeoutMs;

/// 最大重试次数（默认：3）
@property (nonatomic, assign) NSUInteger maxRetries;

/// 是否启用 SDK（默认：YES）
@property (nonatomic, assign) BOOL enabled;

/**
 * 创建默认配置
 */
+ (instancetype)defaultConfig;

@end

NS_ASSUME_NONNULL_END

