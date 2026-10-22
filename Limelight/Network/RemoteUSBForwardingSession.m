#import "RemoteUSBForwardingSession.h"
#import "RemoteUSBReverseTunnel.h"

#import "../Utility/Logger.h"

#import <poll.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <math.h>

static NSString * const MLRemoteUSBErrorDomain = @"com.skyhua.moonlight.remote-usb";
static const NSUInteger kMLRemoteUSBMaxLineBytes = 4096;
static const NSTimeInterval kMLRemoteUSBStartupTimeout = 12.0;

// Each request owns its cancellation pipe. Closing the writer wakes a blocked
// poll immediately without closing/reusing a descriptor from another thread.
@interface MLRemoteUSBOperation : NSObject
@property(nonatomic, strong) NSPipe *cancellationPipe;
@property(atomic, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

@implementation MLRemoteUSBOperation
- (instancetype)init {
    if ((self = [super init])) _cancellationPipe = [NSPipe pipe];
    return self;
}
- (void)cancel {
    @synchronized (self) {
        if (self.cancelled) return;
        self.cancelled = YES;
        [self.cancellationPipe.fileHandleForWriting closeFile];
    }
}
@end

// Read only bytes poll has made available. NSFileHandle.availableData and
// readDataToEndOfFile can block beyond a deadline, even for a partial line.
static NSData *MLRemoteUSBReadOutput(NSFileHandle *handle, MLRemoteUSBOperation *operation,
                                    NSTimeInterval timeout, NSUInteger limit, BOOL firstLine) {
    NSMutableData *data = [NSMutableData data];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    struct pollfd descriptors[] = {
        { handle.fileDescriptor, POLLIN, 0 },
        { operation.cancellationPipe.fileHandleForReading.fileDescriptor, POLLIN, 0 }
    };
    while (!operation.cancelled) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) return nil;
        int milliseconds = (int)MIN(ceil(remaining * 1000.0), (double)INT_MAX);
        int result = poll(descriptors, 2, milliseconds);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0 || descriptors[1].revents || operation.cancelled) return nil;
        if (descriptors[0].revents & (POLLERR | POLLNVAL)) return nil;
        if (!(descriptors[0].revents & (POLLIN | POLLHUP))) continue;
        uint8_t buffer[4096];
        ssize_t count = read(descriptors[0].fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return nil;
        if (count == 0) return data; // Preserve helpers that close stdout without a final newline.
        const uint8_t *newline = firstLine ? memchr(buffer, '\n', (size_t)count) : NULL;
        NSUInteger length = newline ? (NSUInteger)(newline - buffer) : (NSUInteger)count;
        if (length > limit - data.length) return nil;
        [data appendBytes:buffer length:length];
        if (newline) return data;
    }
    return nil;
}

static NSPipe *MLRemoteUSBObserveTaskExit(NSTask *task) {
    NSPipe *exited = [NSPipe pipe];
    task.terminationHandler = ^(NSTask *finishedTask) {
        (void)finishedTask;
        [exited.fileHandleForWriting closeFile];
    };
    return exited;
}

static void MLRemoteUSBWaitForTaskExit(NSPipe *exited, MLRemoteUSBOperation *operation,
                                      NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    struct pollfd descriptors[] = {
        { exited.fileHandleForReading.fileDescriptor, POLLIN, 0 },
        { operation ? operation.cancellationPipe.fileHandleForReading.fileDescriptor : -1, POLLIN, 0 }
    };
    while (!operation.cancelled) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) return;
        int result = poll(descriptors, 2, (int)MIN(ceil(remaining * 1000.0), (double)INT_MAX));
        if (result < 0 && errno == EINTR) continue;
        return;
    }
}

static void MLRemoteUSBTerminateTask(NSTask *task, NSPipe *exited) {
    if (task == nil || !task.running) return;
    [task terminate];
    MLRemoteUSBWaitForTaskExit(exited, nil, 0.25);
    if (task.running) {
        kill(task.processIdentifier, SIGKILL);
        // NSTask reaps the child. Even a broken helper cannot hold the serial
        // queue indefinitely; no waitUntilExit is used during teardown.
        MLRemoteUSBWaitForTaskExit(exited, nil, 1.0);
    }
}

static NSError *MLRemoteUSBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MLRemoteUSBErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @"Remote USB error"}];
}

static id MLRemoteUSBJSONObjectFromData(NSData *data, NSError **errorOut) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        if (errorOut) *errorOut = [NSError errorWithDomain:MLRemoteUSBErrorDomain
                                                       code:4
                                                   userInfo:@{NSLocalizedDescriptionKey: @"The USB/IP exporter returned no data"}];
        return nil;
    }
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text hasPrefix:@"\uFEFF"]) {
        text = [text substringFromIndex:1];
    }

    // The helper contract is one JSON value on stdout. Accept a wrapper
    // object and harmless diagnostic bytes around that value so an older
    // helper cannot make the UI report a misleading format error.
    NSRange firstObject = [text rangeOfString:@"["];
    NSRange firstArray = [text rangeOfString:@"{"];
    NSUInteger start = MIN(firstObject.location == NSNotFound ? NSUIntegerMax : firstObject.location,
                           firstArray.location == NSNotFound ? NSUIntegerMax : firstArray.location);
    if (start != NSUIntegerMax && start > 0) {
        text = [text substringFromIndex:start];
    }
    NSUInteger closeArray = [text rangeOfString:@"]" options:NSBackwardsSearch].location;
    NSUInteger closeObject = [text rangeOfString:@"}" options:NSBackwardsSearch].location;
    NSUInteger end = closeArray == NSNotFound ? closeObject
        : (closeObject == NSNotFound ? closeArray : MAX(closeArray, closeObject));
    if (end != NSNotFound && end + 1 < text.length) {
        text = [text substringToIndex:end + 1];
    }

    NSData *normalized = [text dataUsingEncoding:NSUTF8StringEncoding];
    id object = normalized.length > 0
        ? [NSJSONSerialization JSONObjectWithData:normalized options:0 error:errorOut]
        : nil;
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *wrapper = (NSDictionary *)object;
        object = [wrapper[@"devices"] isKindOfClass:NSArray.class] ? wrapper[@"devices"]
            : ([wrapper[@"usb_devices"] isKindOfClass:NSArray.class] ? wrapper[@"usb_devices"] : object);
    }
    return object;
}

@interface MLRemoteUSBDevice ()
@property(nonatomic, copy, readwrite) NSString *busID;
@property(nonatomic, copy, readwrite) NSString *vidPID;
@property(nonatomic, copy, readwrite) NSString *serial;
@property(nonatomic, copy, readwrite) NSString *manufacturer;
@property(nonatomic, copy, readwrite) NSString *product;
@property(nonatomic, readwrite, getter=isClaimable) BOOL claimable;
@property(nonatomic, readwrite) BOOL isHub;
@end

@implementation MLRemoteUSBDevice

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        id busID = dictionary[@"busId"] ?: dictionary[@"bus_id"] ?: dictionary[@"busID"];
        id vidPID = dictionary[@"vidPid"] ?: dictionary[@"vid_pid"] ?: dictionary[@"vidPID"];
        _busID = [busID isKindOfClass:NSString.class] ? busID : @"";
        _vidPID = [vidPID isKindOfClass:NSString.class] ? vidPID : @"";
        _serial = [dictionary[@"serial"] isKindOfClass:NSString.class] ? dictionary[@"serial"] : @"";
        _manufacturer = [dictionary[@"manufacturer"] isKindOfClass:NSString.class] ? dictionary[@"manufacturer"] : @"";
        _product = [dictionary[@"product"] isKindOfClass:NSString.class] ? dictionary[@"product"] : @"";
        _claimable = [dictionary[@"claimable"] boolValue] || [dictionary[@"available"] boolValue];
        _isHub = [dictionary[@"isHub"] boolValue] || [dictionary[@"is_hub"] boolValue] || [dictionary[@"deviceClass"] integerValue] == 9;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _busID = [coder decodeObjectOfClass:NSString.class forKey:@"busID"] ?: @"";
        _vidPID = [coder decodeObjectOfClass:NSString.class forKey:@"vidPID"] ?: @"";
        _serial = [coder decodeObjectOfClass:NSString.class forKey:@"serial"] ?: @"";
        _manufacturer = [coder decodeObjectOfClass:NSString.class forKey:@"manufacturer"] ?: @"";
        _product = [coder decodeObjectOfClass:NSString.class forKey:@"product"] ?: @"";
        _claimable = [coder decodeBoolForKey:@"claimable"];
        _isHub = [coder decodeBoolForKey:@"isHub"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.busID forKey:@"busID"];
    [coder encodeObject:self.vidPID forKey:@"vidPID"];
    [coder encodeObject:self.serial forKey:@"serial"];
    [coder encodeObject:self.manufacturer forKey:@"manufacturer"];
    [coder encodeObject:self.product forKey:@"product"];
    [coder encodeBool:self.claimable forKey:@"claimable"];
    [coder encodeBool:self.isHub forKey:@"isHub"];
}

- (BOOL)matchesIdentityOfDevice:(MLRemoteUSBDevice *)device {
    if (device == nil || self.vidPID.length == 0 || device.vidPID.length == 0 ||
        [self.vidPID caseInsensitiveCompare:device.vidPID] != NSOrderedSame) {
        return NO;
    }
    // A missing serial is not a stable identity. Keep the conservative result
    // so a port replacement cannot silently inherit an active forwarding slot.
    if (self.serial.length == 0 || device.serial.length == 0) {
        return [self.vidPID caseInsensitiveCompare:device.vidPID] == NSOrderedSame;
    }
    return [self.serial isEqualToString:device.serial];
}

@end

@interface MLRemoteUSBForwardingSession ()
@property(nonatomic, readwrite) MLRemoteUSBForwardingState state;
@property(nonatomic, copy, readwrite) NSArray<MLRemoteUSBDevice *> *devices;
@property(nonatomic, copy, readwrite, nullable) NSError *error;
@property(nonatomic, readwrite) uint16_t localPort;
@property(nonatomic, strong, nullable) NSTask *exporter;
@property(nonatomic, strong, nullable) NSPipe *exporterInput;
@property(nonatomic, strong, nullable) MLRemoteUSBReverseTunnel *tunnel;
@property(nonatomic) dispatch_queue_t workerQueue;
@property(nonatomic, strong, nullable) MLRemoteUSBOperation *operation;
@property(nonatomic, strong, nullable) NSPipe *exporterExited;
@end

@implementation MLRemoteUSBForwardingSession

+ (instancetype)sharedSession {
    static MLRemoteUSBForwardingSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        session = [[MLRemoteUSBForwardingSession alloc] init];
    });
    return session;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = MLRemoteUSBForwardingStateIdle;
        _devices = @[];
        _workerQueue = dispatch_queue_create("com.skyhua.moonlight.remote-usb", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)helperPath {
    if (@available(macOS 13.3, *)) {
        // USB/IP helper is built against the libc++ APIs available from
        // macOS 13.3. The main app still supports macOS 12 without it.
    } else {
        return @"";
    }
    NSString *override = NSProcessInfo.processInfo.environment[@"MOONLIGHT_USB_HELPER"];
    if (override.length > 0) {
        return override;
    }
    NSString *bundlePath = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"moonlight-usbd"];
    return bundlePath ?: @"";
}

// Submission and cancellation use one lock so their worker-queue ordering is
// identical to their request ordering. Long-running work never holds this lock.
- (void)enqueueOperation:(void (^)(MLRemoteUSBOperation *operation))work {
    @synchronized (self) {
        [self.operation cancel];
        MLRemoteUSBOperation *operation = [[MLRemoteUSBOperation alloc] init];
        self.operation = operation;
        dispatch_async(self.workerQueue, ^{
            if (![self isCurrentOperation:operation]) return;
            [self stopSessionLocked];
            if ([self isCurrentOperation:operation]) work(operation);
        });
    }
}

- (BOOL)isCurrentOperation:(MLRemoteUSBOperation *)operation {
    @synchronized (self) {
        return self.operation == operation && !operation.cancelled;
    }
}

- (void)deliverForOperation:(MLRemoteUSBOperation *)operation completion:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if ([self isCurrentOperation:operation]) completion();
        }
    });
}

- (void)refreshDevicesWithCompletion:(void (^)(NSArray<MLRemoteUSBDevice *> *, NSError *))completion {
    [self enqueueOperation:^(MLRemoteUSBOperation *operation) {
        self.state = MLRemoteUSBForwardingStateEnumerating;
        self.error = nil;
        NSString *helperPath = [self helperPath];
        NSError *error = nil;
        NSArray *result = @[];
        NSTask *task = nil;
        NSPipe *exited = nil;
        if (helperPath.length == 0 || ![[NSFileManager defaultManager] isExecutableFileAtPath:helperPath]) {
            error = MLRemoteUSBError(1, @"The macOS USB/IP exporter is not installed");
        } else {
            task = [[NSTask alloc] init];
            NSPipe *output = [NSPipe pipe];
            task.executableURL = [NSURL fileURLWithPath:helperPath];
            task.arguments = @[@"list", @"--json"];
            task.standardOutput = output;
            // An unread stderr pipe can fill and deadlock before stdout arrives.
            task.standardError = NSFileHandle.fileHandleWithNullDevice;
            exited = MLRemoteUSBObserveTaskExit(task);
            if (![task launchAndReturnError:&error]) {
                error = error ?: MLRemoteUSBError(2, @"Unable to start the macOS USB/IP exporter");
            } else {
                NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kMLRemoteUSBStartupTimeout;
                NSData *data = MLRemoteUSBReadOutput(output.fileHandleForReading, operation,
                                                     kMLRemoteUSBStartupTimeout, kMLRemoteUSBMaxLineBytes * 128, NO);
                // EOF does not guarantee process exit. A helper may close stdout
                // and then hang, so the remaining wait shares the same budget.
                NSTimeInterval remaining = MAX(0, deadline - NSProcessInfo.processInfo.systemUptime);
                if (data != nil && !operation.cancelled && task.running) {
                    MLRemoteUSBWaitForTaskExit(exited, operation, remaining);
                }
                if (data == nil || task.running || task.terminationStatus != 0) {
                    error = MLRemoteUSBError(3, @"The USB/IP exporter returned an invalid device list or timed out");
                } else {
                    id object = MLRemoteUSBJSONObjectFromData(data, &error);
                    if ([object isKindOfClass:NSArray.class]) {
                        NSMutableArray *devices = [NSMutableArray array];
                        for (NSDictionary *entry in (NSArray *)object) {
                            if (![entry isKindOfClass:NSDictionary.class]) continue;
                            MLRemoteUSBDevice *device = [[MLRemoteUSBDevice alloc] initWithDictionary:entry];
                            if (device.busID.length > 0 && !device.isHub) [devices addObject:device];
                        }
                        result = devices.copy;
                    } else {
                        error = error ?: MLRemoteUSBError(4, @"The USB/IP exporter returned malformed JSON");
                    }
                }
            }
        }
        MLRemoteUSBTerminateTask(task, exited);
        if (![self isCurrentOperation:operation]) return;
        self.error = error;
        self.state = error ? MLRemoteUSBForwardingStateFailed : MLRemoteUSBForwardingStateIdle;
        if (!error) self.devices = result;
        [self deliverForOperation:operation completion:^{ completion(result, error); }];
    }];
}

// Runs on workerQueue and reports there; the public methods guard delivery to
// the main queue, including the gap between READY and starting the tunnel.
- (void)startExporterForDevice:(MLRemoteUSBDevice *)device
                    operation:(MLRemoteUSBOperation *)operation
                   completion:(void (^)(uint16_t, NSError *))completion {
    self.state = MLRemoteUSBForwardingStateStartingHelper;
    self.error = nil;
    NSError *error = nil;
    if (device == nil || device.busID.length == 0 || !device.claimable) {
        error = MLRemoteUSBError(5, @"The selected USB device cannot be claimed by macOS");
    }
    NSString *helperPath = [self helperPath];
    if (!error && helperPath.length == 0) {
        error = MLRemoteUSBError(6, @"The macOS USB/IP exporter is not installed");
    }
    if (!error) {
        NSTask *task = [[NSTask alloc] init];
        NSPipe *input = [NSPipe pipe];
        NSPipe *output = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:helperPath];
        task.arguments = @[@"serve", @"--bind", device.busID, @"--listen", @"127.0.0.1:0"];
        task.standardInput = input;
        task.standardOutput = output;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSPipe *exited = MLRemoteUSBObserveTaskExit(task);
        if (![task launchAndReturnError:&error]) {
            error = error ?: MLRemoteUSBError(7, @"Unable to start the USB/IP exporter");
        } else {
            self.exporter = task;
            self.exporterExited = exited;
            self.exporterInput = input;
            NSData *lineData = MLRemoteUSBReadOutput(output.fileHandleForReading, operation,
                                                     kMLRemoteUSBStartupTimeout, kMLRemoteUSBMaxLineBytes, YES);
            NSString *line = lineData ? [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding] : nil;
            NSRegularExpression *ready = [NSRegularExpression regularExpressionWithPattern:@"\\AREADY ([1-9][0-9]{0,4})\\z" options:0 error:NULL];
            NSTextCheckingResult *match = [ready firstMatchInString:line ?: @"" options:0 range:NSMakeRange(0, line.length)];
            NSInteger port = match ? [[line substringWithRange:[match rangeAtIndex:1]] integerValue] : 0;
            if (port <= 0 || port > UINT16_MAX || ![self isCurrentOperation:operation]) {
                [self stopExporterLocked];
                error = MLRemoteUSBError(8, line.length > 0 ? line : @"The USB/IP exporter did not become ready");
            } else {
                self.localPort = (uint16_t)port;
            }
        }
    }
    if (![self isCurrentOperation:operation]) return;
    self.state = error ? MLRemoteUSBForwardingStateFailed : MLRemoteUSBForwardingStateReady;
    self.error = error;
    completion(self.localPort, error);
}

- (void)startExporterForDevice:(MLRemoteUSBDevice *)device
                    completion:(void (^)(uint16_t, NSError *))completion {
    [self enqueueOperation:^(MLRemoteUSBOperation *operation) {
        [self startExporterForDevice:device operation:operation completion:^(uint16_t port, NSError *error) {
            [self deliverForOperation:operation completion:^{ completion(port, error); }];
        }];
    }];
}

- (void)stopExporterLocked {
    NSTask *task = self.exporter;
    NSPipe *exited = self.exporterExited;
    [self.exporterInput.fileHandleForWriting closeFile];
    self.exporter = nil;
    self.exporterInput = nil;
    self.exporterExited = nil;
    self.localPort = 0;
    MLRemoteUSBTerminateTask(task, exited);
}

- (void)stopSessionLocked {
    [self.tunnel stop];
    self.tunnel = nil;
    [self stopExporterLocked];
}

- (void)startForwardingForDevice:(MLRemoteUSBDevice *)device
                            host:(NSString *)host
                            port:(uint16_t)port
                           token:(NSString *)token
                      serverCert:(NSData *)serverCert
                       completion:(void (^)(NSError * _Nullable))completion {
    [self enqueueOperation:^(MLRemoteUSBOperation *operation) {
        [self startExporterForDevice:device operation:operation completion:^(uint16_t localPort, NSError *error) {
            if (error) {
                [self deliverForOperation:operation completion:^{ completion(error); }];
                return;
            }
            if (![self isCurrentOperation:operation]) return;
            MLRemoteUSBReverseTunnel *tunnel = [[MLRemoteUSBReverseTunnel alloc] init];
            self.tunnel = tunnel;
            self.state = MLRemoteUSBForwardingStateForwarding;
            __weak MLRemoteUSBForwardingSession *weakSelf = self;
            __weak MLRemoteUSBReverseTunnel *weakTunnel = tunnel;
            [tunnel startWithHost:host port:port token:token busID:device.busID
                      localPort:localPort serverCert:serverCert completion:^(NSError *tunnelError) {
                MLRemoteUSBForwardingSession *session = weakSelf;
                MLRemoteUSBReverseTunnel *completedTunnel = weakTunnel;
                if (!session || !completedTunnel) return;
                dispatch_async(session.workerQueue, ^{
                    if (![session isCurrentOperation:operation] || session.tunnel != completedTunnel) return;
                    if (tunnelError) {
                        session.error = tunnelError;
                        session.state = MLRemoteUSBForwardingStateFailed;
                    }
                    [session deliverForOperation:operation completion:^{ completion(tunnelError); }];
                });
            }];
        }];
    }];
}

- (void)stop {
    @synchronized (self) {
        [self.operation cancel];
        self.operation = nil;
        dispatch_async(self.workerQueue, ^{
            self.state = MLRemoteUSBForwardingStateStopping;
            [self stopSessionLocked];
            self.state = MLRemoteUSBForwardingStateIdle;
        });
    }
}

- (void)dealloc {
    [_operation cancel];
    // Do not enqueue a block retaining a deallocating self. The queue retains
    // only the resources that still need teardown.
    NSTask *task = _exporter;
    NSPipe *input = _exporterInput;
    NSPipe *exited = _exporterExited;
    MLRemoteUSBReverseTunnel *tunnel = _tunnel;
    dispatch_async(_workerQueue, ^{
        [tunnel stop];
        [input.fileHandleForWriting closeFile];
        MLRemoteUSBTerminateTask(task, exited);
    });
}

@end
