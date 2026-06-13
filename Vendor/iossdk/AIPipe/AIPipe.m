//
//  AIPipe.m
//  AIPipe
//
//  Created by AIPipe Team
//

#import "AIPipe.h"
#import <signal.h>

static NSString *const kUserDefaultsKeyQueue = @"AIPipeLogQueue";
static NSString *const kUserDefaultsKeyConfig = @"AIPipeConfig";
static const NSUInteger kMaxBatchSize = 50;
static const NSTimeInterval kDefaultBatchTimeout = 5.0;
static NSUncaughtExceptionHandler *AIPipePreviousExceptionHandler = NULL;

static void AIPipeUncaughtExceptionHandler(NSException *exception);

@interface AIPipe ()

@property (nonatomic, strong) AIPipeConfig *config;
@property (nonatomic, strong) NSMutableArray<AIPipeLogItem *> *logQueue;
@property (nonatomic, strong) NSTimer *batchTimer;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) NSUncaughtExceptionHandler *previousExceptionHandler;
@property (nonatomic, assign) BOOL isInitialized;

static void AIPipeSignalHandler(int signal);

@end

@implementation AIPipe

+ (instancetype)sharedInstance {
    static AIPipe *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AIPipe alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logQueue = [NSMutableArray array];
        _queue = dispatch_queue_create("com.aipipe.queue", DISPATCH_QUEUE_SERIAL);
        _isInitialized = NO;
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 10.0;
        config.timeoutIntervalForResource = 30.0;
        _urlSession = [NSURLSession sessionWithConfiguration:config];
        
        [self loadQueueFromUserDefaults];
    }
    return self;
}

+ (void)initializeWithAPIKey:(NSString *)apiKey endpoint:(NSString *)endpoint {
    AIPipeConfig *config = [AIPipeConfig defaultConfig];
    config.apiKey = apiKey;
    config.endpoint = endpoint;
    [self initializeWithConfig:config];
}

+ (void)initializeWithConfig:(AIPipeConfig *)config {
    AIPipe *instance = [self sharedInstance];
    instance.config = config;
    instance.isInitialized = YES;
    [instance saveConfigToUserDefaults];
    [instance setupExceptionHandler];
    [instance setupSignalHandler];
    [instance startBatchTimer];
}

+ (void)logWithLevel:(NSString *)level content:(NSString *)content format:(nullable NSString *)format {
    AIPipe *instance = [self sharedInstance];
    if (!instance.isInitialized || !instance.config.enabled) {
        return;
    }
    
    AIPipeLogItem *item = [[AIPipeLogItem alloc] init];
    item.content = content;
    item.level = level ?: @"INFO";
    item.format = format ?: instance.config.format;
    item.timestamp = [self currentTimestamp];
    item.topic = instance.config.topic;
    
    [instance addLogToQueue:item];
}

+ (void)logWithLevel:(NSString *)level content:(NSString *)content {
    [self logWithLevel:level content:content format:nil];
}

+ (void)logException:(NSException *)exception format:(nullable NSString *)format {
    AIPipe *instance = [self sharedInstance];
    if (!instance.isInitialized || !instance.config.enabled) {
        return;
    }
    
    NSMutableString *content = [NSMutableString string];
    [content appendFormat:@"Exception: %@\n", exception.name];
    [content appendFormat:@"Reason: %@\n", exception.reason];
    [content appendFormat:@"Call Stack:\n"];
    for (NSString *symbol in exception.callStackSymbols) {
        [content appendFormat:@"  %@\n", symbol];
    }
    
    AIPipeLogItem *item = [[AIPipeLogItem alloc] init];
    item.content = [content copy];
    item.level = @"ERROR";
    item.format = format ?: instance.config.format;
    item.timestamp = [self currentTimestamp];
    item.topic = instance.config.topic;
    
    [instance addLogToQueue:item];
    [instance flushQueue];
}

+ (void)logException:(NSException *)exception {
    [self logException:exception format:nil];
}

+ (void)logError:(NSError *)error format:(nullable NSString *)format {
    AIPipe *instance = [self sharedInstance];
    if (!instance.isInitialized || !instance.config.enabled) {
        return;
    }
    
    NSMutableString *content = [NSMutableString string];
    [content appendFormat:@"Error Domain: %@\n", error.domain];
    [content appendFormat:@"Error Code: %ld\n", (long)error.code];
    [content appendFormat:@"Error Description: %@\n", error.localizedDescription];
    if (error.userInfo) {
        [content appendFormat:@"User Info: %@\n", error.userInfo];
    }
    
    AIPipeLogItem *item = [[AIPipeLogItem alloc] init];
    item.content = [content copy];
    item.level = @"ERROR";
    item.format = format ?: instance.config.format;
    item.timestamp = [self currentTimestamp];
    item.topic = instance.config.topic;
    
    [instance addLogToQueue:item];
}

+ (void)logError:(NSError *)error {
    [self logError:error format:nil];
}

+ (void)flush {
    [[self sharedInstance] flushQueue];
}

+ (void)setEnabled:(BOOL)enabled {
    AIPipe *instance = [self sharedInstance];
    instance.config.enabled = enabled;
    [instance saveConfigToUserDefaults];
}

- (void)addLogToQueue:(AIPipeLogItem *)item {
    dispatch_async(self.queue, ^{
        [self.logQueue addObject:item];
        [self saveQueueToUserDefaults];
        
        // 如果达到批量大小，立即上报
        if (self.logQueue.count >= self.config.batchSize) {
            [self flushQueue];
        }
    });
}

- (void)flushQueue {
    dispatch_async(self.queue, ^{
        if (self.logQueue.count == 0 || !self.config.enabled) {
            return;
        }
        
        NSArray<AIPipeLogItem *> *logsToSend = [self.logQueue copy];
        [self.logQueue removeAllObjects];
        [self saveQueueToUserDefaults];
        
        [self sendBatch:logsToSend retryCount:0];
    });
}

- (void)sendBatch:(NSArray<AIPipeLogItem *> *)logs retryCount:(NSUInteger)retryCount {
    if (logs.count == 0) {
        return;
    }
    
    NSMutableArray *logsArray = [NSMutableArray array];
    for (AIPipeLogItem *item in logs) {
        NSDictionary *dict = [item toDictionary];
        if (dict) {
            [logsArray addObject:dict];
        }
    }
    
    NSMutableDictionary *requestBody = [NSMutableDictionary dictionary];
    requestBody[@"logs"] = logsArray;
    requestBody[@"source"] = self.config.source;
    if (self.config.topic) {
        requestBody[@"topic"] = self.config.topic;
    }
    
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:requestBody options:0 error:&jsonError];
    if (jsonError) {
        NSLog(@"[AIPipe] 构建请求失败: %@", jsonError.localizedDescription);
        [self handleSendFailure:logs retryCount:retryCount];
        return;
    }
    
    NSString *urlString = self.config.endpoint;
    if (![urlString hasSuffix:@"/"]) {
        urlString = [urlString stringByAppendingString:@"/"];
    }
    urlString = [urlString stringByAppendingString:@"logs/ingest-batch"];
    
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.config.apiKey forHTTPHeaderField:@"X-API-Key"];
    request.HTTPBody = jsonData;
    
    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[AIPipe] 上报失败: %@", error.localizedDescription);
            [self handleSendFailure:logs retryCount:retryCount];
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            NSLog(@"[AIPipe] 成功上报 %lu 条日志", (unsigned long)logs.count);
        } else {
            NSLog(@"[AIPipe] 上报失败: HTTP %ld", (long)httpResponse.statusCode);
            [self handleSendFailure:logs retryCount:retryCount];
        }
    }];
    
    [task resume];
}

- (void)handleSendFailure:(NSArray<AIPipeLogItem *> *)logs retryCount:(NSUInteger)retryCount {
    if (retryCount < self.config.maxRetries) {
        // 延迟重试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((retryCount + 1) * NSEC_PER_SEC)), self.queue, ^{
            [self sendBatch:logs retryCount:retryCount + 1];
        });
    } else {
        // 达到最大重试次数，重新加入队列
        dispatch_async(self.queue, ^{
            [self.logQueue insertObjects:logs atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, logs.count)]];
            [self saveQueueToUserDefaults];
        });
    }
}

- (void)setupExceptionHandler {
    self.previousExceptionHandler = NSGetUncaughtExceptionHandler();
    AIPipePreviousExceptionHandler = self.previousExceptionHandler;
    NSSetUncaughtExceptionHandler(&AIPipeUncaughtExceptionHandler);
}

static void AIPipeUncaughtExceptionHandler(NSException *exception) {
    [AIPipe logException:exception];
    [AIPipe flush];

    if (AIPipePreviousExceptionHandler) {
        AIPipePreviousExceptionHandler(exception);
    }
}

- (void)setupSignalHandler {
    signal(SIGABRT, AIPipeSignalHandler);
    signal(SIGILL, AIPipeSignalHandler);
    signal(SIGSEGV, AIPipeSignalHandler);
    signal(SIGFPE, AIPipeSignalHandler);
    signal(SIGBUS, AIPipeSignalHandler);
    signal(SIGPIPE, AIPipeSignalHandler);
}

static void AIPipeSignalHandler(int signal) {
    NSString *signalName = @"UNKNOWN";
    switch (signal) {
        case SIGABRT: signalName = @"SIGABRT"; break;
        case SIGILL: signalName = @"SIGILL"; break;
        case SIGSEGV: signalName = @"SIGSEGV"; break;
        case SIGFPE: signalName = @"SIGFPE"; break;
        case SIGBUS: signalName = @"SIGBUS"; break;
        case SIGPIPE: signalName = @"SIGPIPE"; break;
    }
    
    NSString *content = [NSString stringWithFormat:@"Signal received: %@ (%d)", signalName, signal];
    [AIPipe logWithLevel:@"ERROR" content:content];
    [AIPipe flush];
}

- (void)startBatchTimer {
    [self stopBatchTimer];
    
    NSTimeInterval timeout = self.config.batchTimeoutMs / 1000.0;
    if (timeout <= 0) {
        timeout = kDefaultBatchTimeout;
    }
    
    self.batchTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                        target:self
                                                      selector:@selector(batchTimerFired)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)stopBatchTimer {
    if (self.batchTimer) {
        [self.batchTimer invalidate];
        self.batchTimer = nil;
    }
}

- (void)batchTimerFired {
    if (self.logQueue.count > 0) {
        [self flushQueue];
    }
}

- (void)saveQueueToUserDefaults {
    NSMutableArray *queueData = [NSMutableArray array];
    for (AIPipeLogItem *item in self.logQueue) {
        NSDictionary *dict = [item toDictionary];
        if (dict) {
            [queueData addObject:dict];
        }
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:queueData forKey:kUserDefaultsKeyQueue];
    [defaults synchronize];
}

- (void)loadQueueFromUserDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *queueData = [defaults arrayForKey:kUserDefaultsKeyQueue];
    
    if (queueData) {
        for (NSDictionary *dict in queueData) {
            AIPipeLogItem *item = [[AIPipeLogItem alloc] init];
            item.content = dict[@"content"];
            item.format = dict[@"format"];
            item.level = dict[@"level"];
            item.timestamp = dict[@"timestamp"];
            item.filePath = dict[@"file_path"];
            item.topic = dict[@"topic"];
            [self.logQueue addObject:item];
        }
    }
}

- (void)saveConfigToUserDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *configDict = @{
        @"apiKey": self.config.apiKey ?: @"",
        @"endpoint": self.config.endpoint ?: @"",
        @"source": self.config.source ?: @"ios",
        @"format": self.config.format ?: @"ios",
        @"topic": self.config.topic ?: @"",
        @"batchSize": @(self.config.batchSize),
        @"batchTimeoutMs": @(self.config.batchTimeoutMs),
        @"maxRetries": @(self.config.maxRetries),
        @"enabled": @(self.config.enabled)
    };
    [defaults setObject:configDict forKey:kUserDefaultsKeyConfig];
    [defaults synchronize];
}

+ (NSString *)currentTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

@end
