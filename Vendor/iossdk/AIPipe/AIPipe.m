//
//  AIPipe.m
//  AIPipe
//
//  Created by AIPipe Team
//

#import "AIPipe.h"
#import <signal.h>
#import <unistd.h>

static NSString *const kUserDefaultsKeyQueue = @"AIPipeLogQueue";
static NSString *const kUserDefaultsKeyConfig = @"AIPipeConfig";
static const NSUInteger kMaxBatchSize = 50;
static const NSTimeInterval kDefaultBatchTimeout = 5.0;
// 内存队列硬上限：超限丢最旧。无上限的 logQueue + 每条全量落盘曾把进程
// 推到 126GB MALLOC_SMALL(见 handleSendFailure 无丢弃回插 + O(n²) 落盘)。
static const NSUInteger kMaxQueueSize = 1000;
// 落盘节流窗口：窗口内多次入队只落盘一次。
static const NSTimeInterval kQueueSaveThrottleInterval = 1.0;
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
// 仅在 self.queue 上读写：标记本节流窗口内已有一次落盘被排期。
@property (nonatomic, assign) BOOL queueSaveScheduled;
// 落盘目标；nil 表示 standardUserDefaults。仅测试会替换。
@property (atomic, strong, nullable) NSUserDefaults *persistenceDefaultsOverride;

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
        [self trimQueueToLimit];
        [self scheduleQueueSave];

        // 如果达到批量大小，立即上报
        if (self.logQueue.count >= self.config.batchSize) {
            [self flushQueue];
        }
    });
}

// 仅在 self.queue 上调用。
- (void)trimQueueToLimit {
    if (self.logQueue.count > kMaxQueueSize) {
        NSUInteger overflow = self.logQueue.count - kMaxQueueSize;
        [self.logQueue removeObjectsInRange:NSMakeRange(0, overflow)];
    }
}

// 仅在 self.queue 上调用。节流窗口内的多次入队合并为一次全量落盘，
// 避免每条日志 O(n) 序列化叠成 O(n²)。
- (void)scheduleQueueSave {
    if (self.queueSaveScheduled) {
        return;
    }
    self.queueSaveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kQueueSaveThrottleInterval * NSEC_PER_SEC)),
                   self.queue, ^{
        self.queueSaveScheduled = NO;
        [self saveQueueToUserDefaults];
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
        // 达到最大重试次数，重新插回队头；超出上限时丢最旧，防止
        // 网络长期不可用时整批日志无限回插堆积。
        dispatch_async(self.queue, ^{
            [self.logQueue insertObjects:logs atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, logs.count)]];
            [self trimQueueToLimit];
            [self scheduleQueueSave];
        });
    }
}

- (void)setupExceptionHandler {
    @synchronized ([AIPipe class]) {
        NSUncaughtExceptionHandler *current = NSGetUncaughtExceptionHandler();
        // Reinitializing the SDK must not chain our handler back to itself.
        if (current == &AIPipeUncaughtExceptionHandler) {
            return;
        }
        self.previousExceptionHandler = current;
        AIPipePreviousExceptionHandler = current;
        NSSetUncaughtExceptionHandler(&AIPipeUncaughtExceptionHandler);
    }
}

static void AIPipeUncaughtExceptionHandler(NSException *exception) {
    [AIPipe logException:exception];
    [AIPipe flush];

    if (AIPipePreviousExceptionHandler && AIPipePreviousExceptionHandler != &AIPipeUncaughtExceptionHandler) {
        AIPipePreviousExceptionHandler(exception);
    }
}

- (void)setupSignalHandler {
    // SIGPIPE 是网络/子进程断开管道的日常信号，不是崩溃：直接忽略，绝不进
    // handler。曾因 handler 内 malloc/dispatch 在高频 SIGPIPE 下堆出 126GB。
    signal(SIGPIPE, SIG_IGN);

    signal(SIGABRT, AIPipeSignalHandler);
    signal(SIGILL, AIPipeSignalHandler);
    signal(SIGSEGV, AIPipeSignalHandler);
    signal(SIGFPE, AIPipeSignalHandler);
    signal(SIGBUS, AIPipeSignalHandler);
}

// 致命信号 handler：只允许 async-signal-safe 操作（栈上缓冲 + write(2)）。
// 禁止 ObjC 消息、malloc、dispatch、网络——实测曾有两个线程同时死锁在
// handler 内的 malloc 上。写完立即恢复默认处置并重抛，让系统崩溃流程继续。
static void AIPipeSignalHandler(int sig) {
    const char *name = "UNKNOWN";
    switch (sig) {
        case SIGABRT: name = "SIGABRT"; break;
        case SIGILL: name = "SIGILL"; break;
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGFPE: name = "SIGFPE"; break;
        case SIGBUS: name = "SIGBUS"; break;
    }

    char buf[64];
    size_t len = 0;
    const char *prefix = "[AIPipe] fatal signal: ";
    for (const char *p = prefix; *p != '\0' && len < sizeof(buf) - 1; p++) {
        buf[len++] = *p;
    }
    for (const char *p = name; *p != '\0' && len < sizeof(buf) - 1; p++) {
        buf[len++] = *p;
    }
    if (len < sizeof(buf) - 1) {
        buf[len++] = '\n';
    }
    (void)write(STDERR_FILENO, buf, len);

    signal(sig, SIG_DFL);
    raise(sig);
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

static NSUInteger AIPipeQueueSaveCount = 0;

- (NSUserDefaults *)persistenceDefaults {
    return self.persistenceDefaultsOverride ?: [NSUserDefaults standardUserDefaults];
}

- (void)saveQueueToUserDefaults {
    AIPipeQueueSaveCount += 1;
    NSMutableArray *queueData = [NSMutableArray array];
    for (AIPipeLogItem *item in self.logQueue) {
        NSDictionary *dict = [item toDictionary];
        if (dict) {
            [queueData addObject:dict];
        }
    }

    NSUserDefaults *defaults = [self persistenceDefaults];
    [defaults setObject:queueData forKey:kUserDefaultsKeyQueue];
}

- (void)loadQueueFromUserDefaults {
    NSUserDefaults *defaults = [self persistenceDefaults];
    NSArray *queueData = [defaults arrayForKey:kUserDefaultsKeyQueue];

    // 落盘数据可能来自未设上限的旧版本：只取最新 kMaxQueueSize 条。
    if (queueData.count > kMaxQueueSize) {
        queueData = [queueData subarrayWithRange:NSMakeRange(queueData.count - kMaxQueueSize, kMaxQueueSize)];
    }

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
    NSUserDefaults *defaults = [self persistenceDefaults];
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

#pragma mark - Test Support

+ (NSUInteger)pendingLogCountForTesting {
    AIPipe *instance = [self sharedInstance];
    __block NSUInteger count = 0;
    dispatch_sync(instance.queue, ^{
        count = instance.logQueue.count;
    });
    return count;
}

+ (NSArray<NSString *> *)pendingLogContentsForTesting {
    AIPipe *instance = [self sharedInstance];
    __block NSArray<NSString *> *contents = @[];
    dispatch_sync(instance.queue, ^{
        NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:instance.logQueue.count];
        for (AIPipeLogItem *item in instance.logQueue) {
            [result addObject:item.content ?: @""];
        }
        contents = [result copy];
    });
    return contents;
}

+ (NSUInteger)queueSaveCountForTesting {
    AIPipe *instance = [self sharedInstance];
    __block NSUInteger count = 0;
    dispatch_sync(instance.queue, ^{
        count = AIPipeQueueSaveCount;
    });
    return count;
}

+ (void)resetQueueForTesting {
    AIPipe *instance = [self sharedInstance];
    dispatch_sync(instance.queue, ^{
        [instance.logQueue removeAllObjects];
        AIPipeQueueSaveCount = 0;
        [[instance persistenceDefaults] removeObjectForKey:kUserDefaultsKeyQueue];
    });
}

+ (void)setPersistenceDefaultsForTesting:(nullable NSUserDefaults *)defaults {
    AIPipe *instance = [self sharedInstance];
    // 在串行队列上切换，已排期的节流落盘要么落到旧目标、要么落到新目标，
    // 不会半途读到另一个。
    dispatch_sync(instance.queue, ^{
        instance.persistenceDefaultsOverride = defaults;
    });
}

+ (NSString *)currentTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

@end
