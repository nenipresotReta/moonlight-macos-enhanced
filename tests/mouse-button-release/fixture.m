#import <AppKit/AppKit.h>
#include <assert.h>
#include <limits.h>
#include <math.h>
#define BUTTON_LEFT 1
#define BUTTON_MIDDLE 2
#define BUTTON_RIGHT 3
#define BUTTON_X1 4
#define BUTTON_X2 5
#define BUTTON_ACTION_PRESS 1
#define BUTTON_ACTION_RELEASE 2
#define LOG_W 0
#define Log(...) ((void)0)
/* MENU GESTURE */
typedef struct { void *connectionContext; BOOL initialized; } InputContext;
typedef InputContext *PML_INPUT_STREAM_CONTEXT;
typedef void *PML_CONNECTION_CONTEXT;
static InputContext context = {.initialized = YES}, replacement = {.initialized = YES};
static BOOL swapButtons;
static NSMutableArray<NSDictionary *> *packets;
static dispatch_block_t packetHook;
static void LiSetThreadConnectionContext(void *ctx) {}
static uint64_t LiGetMillis(void) { return 1; }
static bool LiInputContextIsInitialized(InputContext *ctx) { return ctx->initialized; }
static void *LiInputContextGetConnectionCtx(InputContext *ctx) { return ctx->connectionContext; }
static void LiSendMouseButtonEventCtx(InputContext *ctx, int action, int button) {
    if (packetHook) packetHook();
    @synchronized (packets) { [packets addObject:@{@"ctx": [NSValue valueWithPointer:ctx], @"action": @(action), @"button": @(button)}]; }
}
static void LiSendMousePositionEventCtx(InputContext *ctx, short x, short y, short w, short h) {
    @synchronized (packets) { [packets addObject:@{@"position": @YES, @"x": @(x)}]; }
}
static void LiSendMultiControllerEventCtx(InputContext *ctx, int p, int m, int b, int l, int r, int x, int y, int z, int w) {}
@interface Host : NSObject
@property NSString *uuid;
@end
@implementation Host
@end
@interface Controller : NSObject
@property int playerIndex;
@property ControllerMenuGesture menuGesture;
@end
@implementation Controller
@end
@interface Touchpad : NSObject
@property BOOL consumed;
@property NSUInteger resets;
- (void)reset;
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed;
@end
@implementation Touchpad
- (void)reset { self.resets++; }
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed { return self.consumed; }
@end
@class HIDAbsolutePointerBatch;
@interface HIDSupport : NSObject {
    BOOL _shouldSendInputEvents;
    void *_inputContext;
}
/* PROPERTIES */
@property Host *host;
@property Controller *controller;
@property Touchpad *precisionTouchpad;
@property BOOL shouldSendInputEvents;
@property(nonatomic) void *inputContext;
@property NSInteger controllerDriver;
@property BOOL gamepadMenuPressed;
- (void)releaseAllPressedMouseButtons;
@end
@interface SettingsClass : NSObject
+ (BOOL)swapMouseButtonsFor:(NSString *)key;
+ (BOOL)shouldUseHybridFreeMouseMotionFor:(NSString *)key;
+ (NSString *)mouseModeFor:(NSString *)key;
@end
@implementation SettingsClass
+ (BOOL)swapMouseButtonsFor:(NSString *)key { return swapButtons; }
+ (BOOL)shouldUseHybridFreeMouseMotionFor:(NSString *)key { return YES; }
+ (NSString *)mouseModeFor:(NSString *)key { return @"remote"; }
@end
/* HELPERS */
@implementation HIDSupport
@synthesize inputContext = _inputContext;
- (void)releaseAllModifierKeys {}
- (void)sendControllerEvent {}
- (void)rumbleLowFreqMotor:(int)low highFreqMotor:(int)high {}
- (void)syncScrollTraceDiagnosticsPreferenceToInputContext {}
- (void)recordMouseButtonDiagnosticsAction:(NSString *)a button:(int)b mask:(uint32_t)m synthetic:(BOOL)s {}
- (BOOL)reserveDetailedInputDiagnosticsLogSequence:(NSUInteger *)sequence { return NO; }
/* METHODS */
@end
static HIDSupport *support(void) {
    HIDSupport *s = [HIDSupport new];
    s.inputQueue = dispatch_queue_create("test.button-release", DISPATCH_QUEUE_SERIAL);
    s.inputDiagnosticsLock = [NSObject new];
    s.freeMouseVirtualCursorLock = [NSObject new];
    s.precisionTouchpad = [Touchpad new];
    s.controller = [Controller new];
    s.host = [Host new]; s.host.uuid = @"isolated";
    s.inputContext = &context;
    s.shouldSendInputEvents = YES;
    return s;
}
static void drain(HIDSupport *s) { dispatch_sync(s.inputQueue, ^{}); }
static dispatch_semaphore_t pauseQueue(HIDSupport *s) {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(s.inputQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    return gate;
}
static void resumeQueue(HIDSupport *s, dispatch_semaphore_t gate) { dispatch_semaphore_signal(gate); drain(s); }
static void button(HIDSupport *s, int b, BOOL down) {
    [s sendMouseButton:b pressed:down syncedToViewPoint:NSMakePoint(100, 100)
        referenceSize:NSMakeSize(1000, 800) clampToBounds:YES];
}
static void expect(NSArray *expected) {
    NSMutableArray *actual = [NSMutableArray array];
    for (NSDictionary *p in packets) {
        [actual addObject:p[@"position"] ? @"position" : [NSString stringWithFormat:@"%@:%@", p[@"action"], p[@"button"]]];
    }
    if (![actual isEqual:expected]) { NSLog(@"Expected %@; got %@", expected, actual); abort(); }
    [packets removeAllObjects];
}
int main(void) { @autoreleasepool {
    packets = [NSMutableArray array];
    HIDSupport *s = support();
    dispatch_semaphore_t gate = pauseQueue(s);
    [s mouseDown:nil withButton:BUTTON_LEFT];
    [s releaseAllPressedMouseButtons];
    s.shouldSendInputEvents = NO;
    resumeQueue(s, gate);
    expect(@[@"2:1"]);
    assert(![s hasPressedMouseButtons]);
    puts("PASS: uncapture cancels queued press and delivers cleanup while paused");

    s = support(); gate = pauseQueue(s);
    [s mouseDown:nil withButton:BUTTON_LEFT]; [s mouseUp:nil withButton:BUTTON_LEFT];
    resumeQueue(s, gate); expect(@[@"1:1", @"2:1"]);
    gate = pauseQueue(s);
    [s mouseDown:nil withButton:BUTTON_LEFT]; [s mouseUp:nil withButton:BUTTON_LEFT];
    s.shouldSendInputEvents = NO;
    resumeQueue(s, gate); expect(@[@"2:1"]);
    puts("PASS: normal click order and a queued normal release survive pause");

    s = support();
    for (int b = BUTTON_LEFT; b <= BUTTON_X2; b++) [s mouseDown:nil withButton:b];
    drain(s); expect(@[@"1:1", @"1:2", @"1:3", @"1:4", @"1:5"]);
    gate = pauseQueue(s); s.shouldSendInputEvents = NO;
    [s releaseAllPressedMouseButtons];
    resumeQueue(s, gate); expect(@[@"2:1", @"2:2", @"2:3", @"2:4", @"2:5"]);
    assert(![s hasPressedMouseButtons]);
    puts("PASS: all five delivered buttons release exactly once across repeated cleanup");

    s = support(); gate = pauseQueue(s);
    [s mouseDown:nil withButton:BUTTON_LEFT]; s.shouldSendInputEvents = NO;
    s.shouldSendInputEvents = YES;
    [s mouseDown:nil withButton:BUTTON_LEFT]; [s mouseUp:nil withButton:BUTTON_LEFT];
    resumeQueue(s, gate); expect(@[@"2:1", @"1:1", @"2:1"]);
    puts("PASS: fast recapture cannot revive a previous capture's queued press");

    s = support(); gate = pauseQueue(s);
    [s mouseDown:nil withButton:BUTTON_LEFT]; [s releaseAllPressedMouseButtons];
    s.inputContext = &replacement;
    [s mouseDown:nil withButton:BUTTON_RIGHT]; [s mouseUp:nil withButton:BUTTON_RIGHT];
    resumeQueue(s, gate);
    for (NSDictionary *p in packets) assert([p[@"ctx"] pointerValue] == &replacement);
    expect(@[@"1:3", @"2:3"]);
    gate = pauseQueue(s);
    [s mouseDown:nil withButton:BUTTON_LEFT]; [s releaseAllPressedMouseButtons];
    s.inputContext = NULL; s.inputContext = &replacement;
    resumeQueue(s, gate); expect(@[]);
    puts("PASS: context replacement, including pointer reuse, discards old presses and releases");

    s = support(); gate = pauseQueue(s);
    InputContext *retired = malloc(sizeof(*retired)); *retired = context;
    s.inputContext = retired; [s mouseDown:nil withButton:BUTTON_LEFT];
    [s releaseAllPressedMouseButtons]; s.inputContext = NULL; free(retired);
    resumeQueue(s, gate); expect(@[]);
    s.inputContext = &context; gate = pauseQueue(s);
    [s mouseDown:nil withButton:BUTTON_LEFT]; context.initialized = NO;
    [s releaseAllPressedMouseButtons]; resumeQueue(s, gate); expect(@[]);
    context.initialized = YES;
    assert(![s hasPressedMouseButtons]);
    puts("PASS: retired context is not dereferenced and uninitialized input is not sent");

    s = support(); swapButtons = YES;
    [s mouseDown:nil withButton:BUTTON_LEFT]; drain(s); expect(@[@"1:3"]);
    s.shouldSendInputEvents = NO; drain(s); expect(@[@"2:3"]); swapButtons = NO;
    s = support(); s.useGCMouse = YES;
    [s mouseDown:nil withButton:BUTTON_LEFT]; [s mouseUp:nil withButton:BUTTON_LEFT]; button(s, BUTTON_LEFT, YES);
    drain(s); expect(@[]);
    s.useGCMouse = NO; s.precisionTouchpad.consumed = YES;
    [s mouseDown:nil withButton:BUTTON_LEFT]; [s mouseUp:nil withButton:BUTTON_LEFT]; button(s, BUTTON_LEFT, YES);
    [s releaseAllPressedMouseButtons]; drain(s); expect(@[]);
    puts("PASS: swapped buttons, GCMouse ownership and precision touchpad consumption remain isolated");

    s = support(); gate = pauseQueue(s); button(s, BUTTON_LEFT, YES); button(s, BUTTON_LEFT, NO);
    resumeQueue(s, gate); expect(@[@"position", @"1:1", @"2:1"]);
    s = support(); gate = pauseQueue(s); button(s, BUTTON_RIGHT, YES); s.shouldSendInputEvents = NO;
    resumeQueue(s, gate); expect(@[@"2:3"]);
    puts("PASS: absolute position stays paired with its button and cancelled press does not reposition");
    s = support(); gate = pauseQueue(s);
    button(s, BUTTON_LEFT, YES); s.shouldSendInputEvents = NO;
    s.shouldSendInputEvents = YES;
    button(s, BUTTON_LEFT, YES); button(s, BUTTON_LEFT, NO);
    resumeQueue(s, gate); expect(@[@"2:1", @"position", @"1:1", @"2:1"]);
    puts("PASS: same-position recapture resends a position cancelled with an old press");

    s = support();
    dispatch_semaphore_t started = dispatch_semaphore_create(0), finish = dispatch_semaphore_create(0);
    __block BOOL firstPacket = YES;
    packetHook = ^{ if (firstPacket) { firstPacket = NO; dispatch_semaphore_signal(started); dispatch_semaphore_wait(finish, DISPATCH_TIME_FOREVER); } };
    [s mouseDown:nil withButton:BUTTON_LEFT];
    assert(dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    dispatch_group_t paused = dispatch_group_create();
    dispatch_group_async(paused, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ s.shouldSendInputEvents = NO; });
    dispatch_semaphore_signal(finish);
    assert(dispatch_group_wait(paused, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    drain(s); packetHook = nil; expect(@[@"1:1", @"2:1"]);
    puts("PASS: an in-flight send finishes before pause cleanup without losing its release");

    s = support(); gate = pauseQueue(s);
    __block BOOL cleanupRan = NO;
    HIDDispatchInput(s, &context, ^{ cleanupRan = YES; });
    s.shouldSendInputEvents = NO; resumeQueue(s, gate);
    assert(cleanupRan); expect(@[]);
    puts("PASS: generic keyboard/controller cleanup dispatch remains unchanged");
}}
