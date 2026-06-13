//
//  AIPipeLogItem.m
//  AIPipe
//
//  Created by AIPipe Team
//

#import "AIPipeLogItem.h"

@implementation AIPipeLogItem

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    if (self.content) {
        dict[@"content"] = self.content;
    }
    if (self.format) {
        dict[@"format"] = self.format;
    }
    if (self.level) {
        dict[@"level"] = self.level;
    }
    if (self.timestamp) {
        dict[@"timestamp"] = self.timestamp;
    }
    if (self.filePath) {
        dict[@"file_path"] = self.filePath;
    }
    if (self.topic) {
        dict[@"topic"] = self.topic;
    }
    
    return [dict copy];
}

@end

