#import <Foundation/Foundation.h>
#include "Limelight/Network/RemoteUSBForwardingSession.m"

static NSMutableArray<MLRemoteUSBReverseTunnel *> *startedTunnels;
static NSMutableArray<void (^)(NSError *)> *tunnelCompletions;
@interface MLRemoteUSBReverseTunnel ()
@property(nonatomic, copy) void (^completion)(NSError *);
@end
@implementation MLRemoteUSBReverseTunnel
- (void)startWithHost:(NSString *)host port:(uint16_t)port token:(NSString *)token
               busID:(NSString *)busID localPort:(uint16_t)localPort
          serverCert:(NSData *)cert completion:(void (^)(NSError *))completion {
    self.completion = completion; // Production retains this even when stop is called.
    [startedTunnels addObject:self];
    [tunnelCompletions addObject:[completion copy]];
}
- (void)stop {}
@end

static void Require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL PumpUntil(BOOL (^condition)(void), double seconds) {
    double deadline = Now() + seconds;
    while (!condition() && Now() < deadline) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}
static MLRemoteUSBDevice *Device(NSString *mode) {
    return [[MLRemoteUSBDevice alloc] initWithDictionary:@{@"busId":mode, @"claimable":@YES}];
}
static void DrainWorker(MLRemoteUSBForwardingSession *session) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(session.workerQueue, ^{ dispatch_semaphore_signal(done); });
    Require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
            "worker queue is bounded");
}
static void StopAndDrain(MLRemoteUSBForwardingSession *session) {
    [session stop]; DrainWorker(session);
    PumpUntil(^BOOL { return session.state == MLRemoteUSBForwardingStateIdle; }, 1);
}
static void TestReader(void) {
    NSPipe *pipe = [NSPipe pipe];
    MLRemoteUSBOperation *operation = [MLRemoteUSBOperation new];
    double start = Now();
    Require(MLRemoteUSBReadOutput(pipe.fileHandleForReading, operation, 0.05, 4096, YES) == nil,
            "silent pipe times out without waiting for EOF");
    Require(Now() - start < 0.5, "silent pipe respects deadline");
    [pipe.fileHandleForWriting writeData:[@"READY 321" dataUsingEncoding:NSUTF8StringEncoding]];
    Require(MLRemoteUSBReadOutput(pipe.fileHandleForReading, operation, 0.05, 4096, YES) == nil,
            "partial READY does not succeed on timeout");
    [pipe.fileHandleForWriting closeFile];

    pipe = [NSPipe pipe];
    [pipe.fileHandleForWriting writeData:[@"READY " dataUsingEncoding:NSUTF8StringEncoding]];
    NSFileHandle *writer = pipe.fileHandleForWriting;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
        [writer writeData:[@"321\nignored" dataUsingEncoding:NSUTF8StringEncoding]];
    });
    NSData *line = MLRemoteUSBReadOutput(pipe.fileHandleForReading, operation, 1, 4096, YES);
    Require([[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] isEqual:@"READY 321"],
            "split newline-delimited READY is reconstructed exactly");
    [writer closeFile];

    pipe = [NSPipe pipe];
    [pipe.fileHandleForWriting writeData:[@"READY 123" dataUsingEncoding:NSUTF8StringEncoding]];
    [pipe.fileHandleForWriting closeFile];
    line = MLRemoteUSBReadOutput(pipe.fileHandleForReading, operation, 1, 4096, YES);
    Require([[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] isEqual:@"READY 123"],
            "EOF without final newline remains supported");

    pipe = [NSPipe pipe];
    NSMutableData *oversized = [NSMutableData dataWithLength:4098];
    memset(oversized.mutableBytes, 'x', oversized.length);
    ((char *)oversized.mutableBytes)[4097] = '\n';
    [pipe.fileHandleForWriting writeData:oversized];
    Require(MLRemoteUSBReadOutput(pipe.fileHandleForReading, operation, 1, 4096, YES) == nil,
            "overlong line rejected before returning newline data");
    [pipe.fileHandleForWriting closeFile];

    pipe = [NSPipe pipe];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
        [operation cancel];
    });
    start = Now();
    Require(MLRemoteUSBReadOutput(pipe.fileHandleForReading, operation, 12, 4096, YES) == nil,
            "cancellation wakes a silent reader");
    Require(Now() - start < 0.5, "cancellation does not wait for startup deadline");
    [pipe.fileHandleForWriting closeFile];
    puts("PASS: production reader handles silence, partial/split lines, EOF, length limit and cancellation");
}
static void TestStartupDeadline(void) {
    MLRemoteUSBForwardingSession *silent = [MLRemoteUSBForwardingSession new];
    MLRemoteUSBForwardingSession *partial = [MLRemoteUSBForwardingSession new];
    __block int failures = 0;
    double start = Now();
    void (^completion)(uint16_t, NSError *) = ^(uint16_t port, NSError *error) {
        Require(port == 0 && error != nil, "startup deadline delivers failure, not partial READY");
        failures++;
    };
    [silent startExporterForDevice:Device(@"silent") completion:completion];
    [partial startExporterForDevice:Device(@"partial") completion:completion];
    Require(PumpUntil(^BOOL { return failures == 2; }, 14), "both real helpers time out within the startup budget");
    Require(Now() - start >= 11.5 && silent.exporter == nil && partial.exporter == nil,
            "production 12-second timeout cleans up silent and partial-line helpers");
    StopAndDrain(silent); StopAndDrain(partial);
    puts("PASS: real silent/partial-line helpers fail after the production 12-second deadline");
}
static void TestNonblockingStop(void) {
    MLRemoteUSBForwardingSession *session = [MLRemoteUSBForwardingSession new];
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(session.workerQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    double start = Now();
    [session stop];
    Require(Now() - start < 0.1, "stop never waits for occupied worker queue");
    dispatch_semaphore_signal(gate);
    DrainWorker(session);
    puts("PASS: main-thread stop returns while worker queue is deliberately blocked");
}
static void TestSessions(void) {
    MLRemoteUSBForwardingSession *session = [MLRemoteUSBForwardingSession new];
    __block int oldCalls = 0, newCalls = 0;
    [session startExporterForDevice:Device(@"silent") completion:^(uint16_t port, NSError *error) { oldCalls++; }];
    Require(PumpUntil(^BOOL { return session.exporter != nil; }, 1), "silent helper launched");
    NSTask *silentTask = session.exporter;
    double start = Now();
    [session stop];
    Require(Now() - start < 0.1, "stop returns immediately during READY wait");
    DrainWorker(session);
    Require(!silentTask.running && session.localPort == 0, "cancelled helper terminated and port cleared");
    PumpUntil(^BOOL { return oldCalls != 0; }, 0.02);
    Require(oldCalls == 0, "cancelled startup completion discarded");

    [session startExporterForDevice:Device(@"silent") completion:^(uint16_t port, NSError *error) { oldCalls++; }];
    Require(PumpUntil(^BOOL { return session.exporter != nil; }, 1), "replacement test first helper launched");
    silentTask = session.exporter;
    [session startExporterForDevice:Device(@"ready") completion:^(uint16_t port, NSError *error) {
        Require(error == nil && port == 321, "replacement helper is ready"); newCalls++;
    }];
    Require(PumpUntil(^BOOL { return newCalls == 1; }, 2), "replacement startup bypasses cancelled deadline");
    Require(!silentTask.running && oldCalls == 0, "old startup cannot complete into replacement");
    StopAndDrain(session);

    // READY callback is already queued on main, but stop wins before delivery.
    [session startExporterForDevice:Device(@"ready") completion:^(uint16_t port, NSError *error) { oldCalls++; }];
    DrainWorker(session);
    Require(session.localPort == 321, "READY finished on worker");
    [session stop]; DrainWorker(session);
    PumpUntil(^BOOL { return oldCalls != 0; }, 0.02);
    Require(oldCalls == 0, "already queued READY completion cannot revive stopped session");

    __block BOOL ready = NO;
    [session startExporterForDevice:Device(@"ignore-term") completion:^(uint16_t port, NSError *error) {
        Require(error == nil, "TERM-resistant helper ready"); ready = YES;
    }];
    Require(PumpUntil(^BOOL { return ready; }, 1), "TERM-resistant helper launched");
    NSTask *stubbornTask = session.exporter;
    start = Now(); StopAndDrain(session);
    Require(!stubbornTask.running && stubbornTask.terminationStatus == SIGKILL,
            "TERM-resistant helper escalates to SIGKILL and is reaped");
    Require(Now() - start < 1.75, "TERM-resistant cleanup is bounded");

    ready = NO;
    [session startExporterForDevice:Device(@"stderr") completion:^(uint16_t port, NSError *error) {
        Require(error == nil && port == 321, "stderr flood cannot prevent READY"); ready = YES;
    }];
    Require(PumpUntil(^BOOL { return ready; }, 1), "stderr flood does not deadlock helper");
    StopAndDrain(session);

    __block BOOL failed = NO;
    [session startExporterForDevice:Device(@"overlong") completion:^(uint16_t port, NSError *error) {
        Require(error != nil && port == 0, "overlong READY fails"); failed = YES;
    }];
    Require(PumpUntil(^BOOL { return failed; }, 1), "overlong helper failure is delivered");
    Require(session.exporter == nil, "failed helper cleaned up");
    StopAndDrain(session);
    puts("PASS: session stop/replacement, queued READY, TERM-resistant cleanup, stderr flood and malformed helper");
}
static void TestEnumeration(void) {
    MLRemoteUSBForwardingSession *session = [MLRemoteUSBForwardingSession new];
    __block int callbacks = 0;
    setenv("ML_USB_TEST_LIST_MODE", "closed-stdout", 1);
    [session refreshDevicesWithCompletion:^(NSArray *devices, NSError *error) { callbacks++; }];
    Require(PumpUntil(^BOOL { return session.state == MLRemoteUSBForwardingStateEnumerating; }, 1), "enumeration started");
    // Allow the child to close stdout and reach the process-exit wait.
    PumpUntil(^BOOL { return NO; }, 0.05);
    double start = Now(); StopAndDrain(session);
    Require(Now() - start < 1.75 && callbacks == 0, "cancel also wakes wait after stdout EOF");
    setenv("ML_USB_TEST_LIST_MODE", "list", 1);
    [session refreshDevicesWithCompletion:^(NSArray *devices, NSError *error) {
        Require(error == nil && devices.count == 0, "normal enumeration parses empty list"); callbacks++;
    }];
    Require(PumpUntil(^BOOL { return callbacks == 1; }, 1), "enumeration works after cancelled helper");
    StopAndDrain(session);
    puts("PASS: enumeration EOF-without-exit is cancellable and next enumeration succeeds");
}
static void TestTunnelGeneration(void) {
    MLRemoteUSBForwardingSession *session = [MLRemoteUSBForwardingSession new];
    __block int oldCalls = 0, newCalls = 0;
    void (^start)(void (^)(NSError *)) = ^(void (^completion)(NSError *)) {
        [session startForwardingForDevice:Device(@"ready") host:@"test.invalid" port:1 token:@"test"
                               serverCert:[NSData data] completion:completion];
    };
    start(^(NSError *error) { oldCalls++; });
    Require(PumpUntil(^BOOL { return startedTunnels.count == 1; }, 1), "first fake tunnel starts");
    void (^oldCompletion)(NSError *) = tunnelCompletions.firstObject;
    __weak MLRemoteUSBReverseTunnel *oldTunnel = startedTunnels.firstObject;
    [session stop];
    start(^(NSError *error) { Require(error == nil, "current fake tunnel completion"); newCalls++; });
    Require(PumpUntil(^BOOL { return startedTunnels.count == 2; }, 1), "replacement fake tunnel starts");
    oldCompletion([NSError errorWithDomain:@"test" code:1 userInfo:nil]);
    DrainWorker(session);
    Require(session.state == MLRemoteUSBForwardingStateForwarding && session.error == nil,
            "old tunnel failure cannot overwrite new session state");
    [startedTunnels removeObjectAtIndex:0];
    Require(oldTunnel == nil, "stopped tunnel is not retained by its stored completion");
    oldCompletion(nil);
    tunnelCompletions.lastObject(nil);
    Require(PumpUntil(^BOOL { return newCalls == 1; }, 1), "new tunnel completion delivered");
    Require(oldCalls == 0, "old tunnel completion discarded");
    StopAndDrain(session);
    [startedTunnels removeAllObjects]; [tunnelCompletions removeAllObjects];
    puts("PASS: old tunnel callback cannot fail or revive a replacement session");
}
int main(int argc, char **argv) { @autoreleasepool {
    Require(argc == 2, "helper path supplied");
    setenv("MOONLIGHT_USB_HELPER", argv[1], 1);
    startedTunnels = [NSMutableArray array]; tunnelCompletions = [NSMutableArray array];
    TestReader(); TestStartupDeadline(); TestNonblockingStop(); TestSessions(); TestEnumeration(); TestTunnelGeneration();
    puts("PASS: all USB startup regression tests (no USB devices or network)");
    return 0;
} }
