//
//  AIPipe.h
//  AIPipe
//
//  Created by AIPipe Team
//

#import <Foundation/Foundation.h>
#import "AIPipeConfig.h"
#import "AIPipeLogItem.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * AIPipe iOS/macOS SDK
 * 用于捕获异常和日志并上报到AIPipe服务器
 */
@interface AIPipe : NSObject

/**
 * 使用API Key和Endpoint初始化SDK
 * @param apiKey API密钥
 * @param endpoint API端点URL（例如：https://api.example.com/api/v1）
 */
+ (void)initializeWithAPIKey:(NSString *)apiKey endpoint:(NSString *)endpoint;

/**
 * 使用自定义配置初始化SDK
 * @param config 配置对象
 */
+ (void)initializeWithConfig:(AIPipeConfig *)config;

/**
 * 记录日志
 * @param level 日志级别（ERROR, WARN, INFO, DEBUG等）
 * @param content 日志内容
 * @param format 日志格式（可选，默认使用config中的format）
 */
+ (void)logWithLevel:(NSString *)level content:(NSString *)content format:(nullable NSString *)format;

/**
 * 记录日志（使用默认格式）
 * @param level 日志级别
 * @param content 日志内容
 */
+ (void)logWithLevel:(NSString *)level content:(NSString *)content;

/**
 * 记录异常
 * @param exception 异常对象
 * @param format 日志格式（可选）
 */
+ (void)logException:(NSException *)exception format:(nullable NSString *)format;

/**
 * 记录异常（使用默认格式）
 * @param exception 异常对象
 */
+ (void)logException:(NSException *)exception;

/**
 * 记录错误
 * @param error NSError对象
 * @param format 日志格式（可选）
 */
+ (void)logError:(NSError *)error format:(nullable NSString *)format;

/**
 * 记录错误（使用默认格式）
 * @param error NSError对象
 */
+ (void)logError:(NSError *)error;

/**
 * 立即上报队列中的所有日志
 */
+ (void)flush;

/**
 * 设置是否启用SDK
 * @param enabled 是否启用
 */
+ (void)setEnabled:(BOOL)enabled;

/**
 * 获取SDK实例（用于高级用法）
 */
+ (instancetype)sharedInstance;

#pragma mark - Test Support（仅供单元测试使用，业务代码不得调用）

/// 当前内存队列长度（在内部串行队列上同步读取）
+ (NSUInteger)pendingLogCountForTesting;

/// 当前内存队列各条日志的 content
+ (NSArray<NSString *> *)pendingLogContentsForTesting;

/// 进程内累计的队列落盘次数
+ (NSUInteger)queueSaveCountForTesting;

/// 清空内存队列、落盘队列与落盘计数
+ (void)resetQueueForTesting;

@end

NS_ASSUME_NONNULL_END

