//
//  AIPipeLogItem.h
//  AIPipe
//
//  Created by AIPipe Team
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 日志项
 */
@interface AIPipeLogItem : NSObject

/// 日志内容（必需）
@property (nonatomic, strong) NSString *content;

/// 日志格式（必需）
@property (nonatomic, strong) NSString *format;

/// 日志级别（可选，例如：ERROR, WARN, INFO, DEBUG）
@property (nonatomic, strong, nullable) NSString *level;

/// 时间戳（ISO 8601格式，可选）
@property (nonatomic, strong, nullable) NSString *timestamp;

/// 文件路径（可选）
@property (nonatomic, strong, nullable) NSString *filePath;

/// 日志主题（可选）
@property (nonatomic, strong, nullable) NSString *topic;

/**
 * 转换为字典（用于JSON序列化）
 */
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END

