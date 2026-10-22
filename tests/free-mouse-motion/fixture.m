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
#define LOG_D 0
#define Log(...) ((void)0)
/* MENU GESTURE */
typedef struct { void *connectionContext; } InputContext;
typedef InputContext *PML_INPUT_STREAM_CONTEXT;
typedef void *PML_CONNECTION_CONTEXT;
static void LiSetThreadConnectionContext(void *ctx) {}
static InputContext context;
static BOOL validContext = YES, hybrid = YES, swapButtons;
static bool LiInputContextIsInitialized(InputContext *ctx) { return validContext; }
static void *LiInputContextGetConnectionCtx(InputContext *ctx) { return ctx->connectionContext; }
static void LiSendMultiControllerEventCtx(InputContext *ctx, int p, int m, int b, int l, int r, int x, int y, int z, int w) {}
static NSString *mouseMode = @"remote";
static NSInteger touchMode;
static CGFloat sensitivity = 1.0;
static CGFloat const HIDCoreHIDFreeMouseBaselineScale = 0.75;
static NSMutableArray<NSDictionary *> *packets;
static uint64_t LiGetMillis(void) { return 1; }
static void LiSendMousePositionEventCtx(InputContext *ctx, short x, short y, short w, short h) {
    [packets addObject:@{@"x": @(x), @"y": @(y), @"w": @(w), @"h": @(h)}];
}
static void LiSendMouseButtonEventCtx(InputContext *ctx, int action, int button) {
    [packets addObject:@{@"action": @(action), @"button": @(button)}];
}
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
@property BOOL suppressed, consumed;
- (BOOL)shouldSuppressPointerMotion;
- (void)reset;
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed;
@end
@implementation Touchpad
- (void)reset {}
- (BOOL)shouldSuppressPointerMotion { return self.suppressed; }
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed { return self.consumed; }
@end
#define MLPrecisionTouchpad Touchpad
typedef void (^HIDFreeMouseAbsoluteSyncHandler)(void);
@interface GCMouse : NSObject
+ (NSArray *)mice;
@end
@implementation GCMouse
+ (NSArray *)mice { return @[]; }
@end
@class HIDAbsolutePointerBatch;
@interface HIDSupport : NSObject {
    BOOL _shouldSendInputEvents;
    void *_inputContext;
}
/* PROPERTIES */
@property Host *host;
@property BOOL shouldSendInputEvents;
@property(nonatomic) void *inputContext;
@property Controller *controller;
@property NSInteger controllerDriver;
@property BOOL gamepadMenuPressed;
- (void)releaseAllPressedMouseButtons;
@property NSObject *coreHIDMouseDriver;
@property int relativeCalls;
@property (copy) HIDFreeMouseAbsoluteSyncHandler freeMouseAbsoluteSyncHandler;
- (void)sendAbsoluteMousePositionForViewPoint:(NSPoint)p referenceSize:(NSSize)s clampToBounds:(BOOL)c;
- (void)resetFreeMouseVirtualCursorState;
- (BOOL)reserveDetailedInputDiagnosticsLogSequence:(NSUInteger *)sequence;
@end
@interface SettingsClass : NSObject
+ (BOOL)shouldUseHybridFreeMouseMotionFor:(NSString *)key;
+ (NSString *)mouseModeFor:(NSString *)key;
+ (BOOL)swapMouseButtonsFor:(NSString *)key;
+ (NSInteger)touchscreenModeFor:(NSString *)key;
+ (void)updateMouseInputRuntimeStatusFor:(NSString *)key summaryKey:(NSString *)s detailKey:(NSString *)d;
@end
@implementation SettingsClass
+ (BOOL)shouldUseHybridFreeMouseMotionFor:(NSString *)key { return hybrid; }
+ (NSString *)mouseModeFor:(NSString *)key { return mouseMode; }
+ (BOOL)swapMouseButtonsFor:(NSString *)key { return swapButtons; }
+ (NSInteger)touchscreenModeFor:(NSString *)key { return touchMode; }
+ (void)updateMouseInputRuntimeStatusFor:(NSString *)key summaryKey:(NSString *)s detailKey:(NSString *)d {}
@end
// Production mouseMoved queries this property on its fallback path.
@interface NSObject (TestDriver)
@property (readonly) double secondsSinceLastMovementEvent;
@end
static CGFloat HIDPointerSensitivityForHost(Host *h) { return sensitivity; }
static BOOL HIDAbsoluteMousePayloadForEvent(NSEvent *e, BOOL c, short *x, short *y, short *w, short *h) {
    *x = 800; *y = 6400; *w = 16000; *h = 9600; return YES;
}
/* HELPERS */
@implementation HIDSupport
@synthesize inputContext = _inputContext;
- (void)releaseAllModifierKeys {}
- (void)sendControllerEvent {}
- (void)rumbleLowFreqMotor:(int)low highFreqMotor:(int)high {}
- (void)syncScrollTraceDiagnosticsPreferenceToInputContext {}
- (void)registerMouseCallbacks:(GCMouse *)mouse {}
- (void)unregisterMouseCallbacks:(GCMouse *)mouse {}
- (void)tearDownCoreHIDMouseDriver {}
- (void)setupCoreHIDMouseDriverIfNeeded {}
- (BOOL)reserveDetailedInputDiagnosticsLogSequence:(NSUInteger *)sequence { return NO; }
- (void)recordMouseButtonDiagnosticsAction:(NSString *)a button:(int)b mask:(uint32_t)m synthetic:(BOOL)s {}
- (void)dispatchRelativeMouseDeltaX:(CGFloat)x deltaY:(CGFloat)y sourceTag:(NSString *)s { self.relativeCalls++; }
/* METHODS */
@end
static NSSize size(void) { return NSMakeSize(2000, 1200); }
static HIDSupport *support(void) {
    HIDSupport *s = [HIDSupport new];
    s.inputQueue = dispatch_queue_create("test.pointer", DISPATCH_QUEUE_SERIAL);
    s.freeMouseVirtualCursorLock = [NSObject new];
    s.inputDiagnosticsLock = [NSObject new];
    s.controller = [Controller new];
    s.controllerDriver = 1;
    s.inputContext = &context;
    s.shouldSendInputEvents = YES;
    s.useCoreHIDMouse = YES;
    s.precisionTouchpad = [Touchpad new];
    s.host = [Host new]; s.host.uuid = @"isolated";
    [s setFreeMouseVirtualCursorActive:YES];
    [s resetFreeMouseVirtualCursorState];
    return s;
}
static void drain(HIDSupport *s) { dispatch_sync(s.inputQueue, ^{}); }
static dispatch_semaphore_t pauseQueue(HIDSupport *s) {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(s.inputQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    return gate;
}
static void resumeQueue(HIDSupport *s, dispatch_semaphore_t gate) { dispatch_semaphore_signal(gate); drain(s); }
static void raw(HIDSupport *s, double x, double y) { assert([s dispatchVirtualFreeMouseDeltaX:x deltaY:y sourceTag:@"raw"]); }
static void coalesced(HIDSupport *s, double x) {
    [s sendCoalescedAbsoluteMousePositionForViewPoint:NSMakePoint(x, 400) referenceSize:size() clampToBounds:YES sourceTag:@"raw"];
}
static void immediate(HIDSupport *s, double x) {
    [s sendAbsoluteMousePositionForViewPoint:NSMakePoint(x, 400) referenceSize:size() clampToBounds:YES];
}
static void button(HIDSupport *s, int b, BOOL down, double x) {
    [s sendMouseButton:b pressed:down syncedToViewPoint:NSMakePoint(x, 400) referenceSize:size() clampToBounds:YES];
}
static void expect(NSArray *expected) {
    NSMutableArray *actual = [NSMutableArray array];
    for (NSDictionary *p in packets) {
        [actual addObject:p[@"x"] ?: [NSString stringWithFormat:@"%@:%@", p[@"action"], p[@"button"]]];
    }
    if (![actual isEqual:expected]) { NSLog(@"Expected %@; got %@", expected, actual); abort(); }
    [packets removeAllObjects];
}
static void motionTests(void) {
    HIDSupport *s = support();
    [s updateFreeMouseVirtualCursorAnchorWithViewPoint:NSMakePoint(500, 400) referenceSize:size()];
    dispatch_semaphore_t gate = pauseQueue(s);
    for (int i = 0; i < 8; i++) raw(s, 4, 0);
    assert(s.freeMouseVirtualCursorPoint.x == 524);
    assert(![s seedFreeMouseVirtualCursorWithViewPoint:NSMakePoint(512, 400) referenceSize:size()]);
    raw(s, 4, 0);
    assert(s.freeMouseVirtualCursorPoint.x == 527);
    resumeQueue(s, gate); expect(@[@4216]);
    puts("PASS: delayed AppKit samples neither rewind raw motion nor change sensitivity");

    // A click snapshot can be older than raw reports that arrived on another thread.
    gate = pauseQueue(s);
    button(s, BUTTON_LEFT, YES, 500);
    raw(s, 4, -4);
    assert(![s seedFreeMouseVirtualCursorWithViewPoint:NSMakePoint(510, 400) referenceSize:size()]);
    button(s, BUTTON_LEFT, NO, 510);
    raw(s, 4, 0);
    resumeQueue(s, gate); expect(@[@"1:1", @4240, @"2:1", @4264]);
    assert(!s.pressedMouseButtonsMask && s.freeMouseVirtualCursorPoint.y == 403);
    puts("PASS: dragging and button sync use the current trajectory with position before release");

    gate = pauseQueue(s);
    immediate(s, 600); raw(s, 4, 0);
    assert([s sendCurrentFreeMouseVirtualCursorPosition]);
    raw(s, 4, 0);
    resumeQueue(s, gate); expect(@[@4800, @4824, @4848]);
    assert(s.freeMouseVirtualCursorPoint.x == 606);
    puts("PASS: explicit handoff reseeds once and semantic sync submits the latest position");

    gate = pauseQueue(s);
    [s setFreeMouseVirtualCursorActive:NO];
    assert(![s dispatchVirtualFreeMouseDeltaX:4 deltaY:0 sourceTag:@"raw"]);
    [s setFreeMouseVirtualCursorActive:YES];
    assert([s seedFreeMouseVirtualCursorWithViewPoint:NSMakePoint(600, 500) referenceSize:size()]);
    raw(s, 4, 0);
    assert([s seedFreeMouseVirtualCursorWithViewPoint:NSMakePoint(100, 100) referenceSize:NSMakeSize(1000, 600)]);
    raw(s, 4, 0);
    assert(s.freeMouseVirtualCursorPoint.x == 103 && s.freeMouseVirtualCursorReferenceSize.width == 1000);
    resumeQueue(s, gate); [packets removeAllObjects];
    assert(![s seedFreeMouseVirtualCursorWithViewPoint:NSMakePoint(NAN, 0) referenceSize:size()]);
    assert(![s dispatchVirtualFreeMouseDeltaX:NAN deltaY:0 sourceTag:@"raw"]);
    assert(![s seedFreeMouseVirtualCursorWithViewPoint:NSZeroPoint referenceSize:NSZeroSize]);
    sensitivity = 2;
    raw(s, 4, 4); assert(s.freeMouseVirtualCursorPoint.x == 109 && s.freeMouseVirtualCursorPoint.y == 94);
    raw(s, 1e6, -1e6); assert(s.freeMouseVirtualCursorPoint.x == 1000 && s.freeMouseVirtualCursorPoint.y == 600);
    drain(s); [packets removeAllObjects]; sensitivity = 1;
    puts("PASS: recapture, geometry changes, sensitivity, Y direction, bounds and invalid reports");
}
static void queueTests(void) {
    HIDSupport *s = support();
    // Disable virtual ownership to exercise exact explicit sync positions.
    [s setFreeMouseVirtualCursorActive:NO];
    dispatch_semaphore_t gate = pauseQueue(s);
    coalesced(s, 100); immediate(s, 110); coalesced(s, 120);
    resumeQueue(s, gate); expect(@[@800, @880, @960]);
    puts("PASS: queued 100 -> 110 -> 120 is sent in that order under backlog");

    gate = pauseQueue(s);
    coalesced(s, 100); coalesced(s, 105);
    button(s, BUTTON_LEFT, YES, 110);
    coalesced(s, 120); coalesced(s, 125);
    button(s, BUTTON_LEFT, NO, 128); coalesced(s, 140);
    resumeQueue(s, gate); expect(@[@840, @880, @"1:1", @1000, @1024, @"2:1", @1120]);
    gate = pauseQueue(s);
    coalesced(s, 100); button(s, BUTTON_RIGHT, YES, 100); coalesced(s, 120);
    button(s, BUTTON_RIGHT, NO, 120);
    resumeQueue(s, gate); expect(@[@800, @"1:3", @960, @"2:3"]);
    puts("PASS: batches coalesce within boundaries, including clicks at duplicate coordinates");

    gate = pauseQueue(s);
    coalesced(s, 100); [s mouseDown:nil withButton:BUTTON_MIDDLE]; coalesced(s, 110);
    [s mouseUp:nil withButton:BUTTON_MIDDLE]; coalesced(s, 120);
    resumeQueue(s, gate); expect(@[@800, @"1:2", @880, @"2:2", @960]);
    swapButtons = YES;
    button(s, BUTTON_LEFT, YES, 120); button(s, BUTTON_LEFT, NO, 120);
    drain(s); expect(@[@"1:3", @"2:3"]); swapButtons = NO;
    puts("PASS: unsynced button ordering, button swap and pressed state");

    gate = pauseQueue(s); coalesced(s, 150); s.shouldSendInputEvents = NO;
    resumeQueue(s, gate); expect(@[]);
    s.shouldSendInputEvents = YES; coalesced(s, 150); drain(s); expect(@[@1200]);
    gate = pauseQueue(s); coalesced(s, 160); s.precisionTouchpad.suppressed = YES;
    resumeQueue(s, gate); expect(@[]);
    s.precisionTouchpad.suppressed = NO; coalesced(s, 160); drain(s); expect(@[@1280]);
    validContext = NO; coalesced(s, 170); immediate(s, 180); button(s, BUTTON_LEFT, YES, 180);
    drain(s); expect(@[]); validContext = YES;
    s.precisionTouchpad.consumed = YES; button(s, BUTTON_LEFT, YES, 180); drain(s); expect(@[]);
    puts("PASS: input disable, touchpad suppression, invalid context and consumed buttons");

    HIDSupport *released = support();
    [released setFreeMouseVirtualCursorActive:NO];
    gate = pauseQueue(released);
    coalesced(released, 100);
    [released mouseDown:nil withButton:BUTTON_LEFT];
    coalesced(released, 110);
    [released releaseAllPressedMouseButtons];
    coalesced(released, 120);
    resumeQueue(released, gate);
    expect(@[@800, @880, @"2:1", @960]);
    gate = pauseQueue(released);
    button(released, BUTTON_LEFT, YES, 150);
    released.shouldSendInputEvents = NO;
    released.shouldSendInputEvents = YES;
    button(released, BUTTON_LEFT, YES, 150);
    button(released, BUTTON_LEFT, NO, 150);
    resumeQueue(released, gate);
    expect(@[@"2:1", @1200, @"1:1", @"2:1"]);
    puts("PASS: synthetic release seals motion batches and recapture resends a cancelled click position");
}
static void isolationTests(void) {
    HIDSupport *s = support();
    [s updateFreeMouseVirtualCursorAnchorWithViewPoint:NSMakePoint(500, 400) referenceSize:size()];
    hybrid = NO; assert(![s dispatchVirtualFreeMouseDeltaX:4 deltaY:0 sourceTag:@"raw"]);
    assert(HIDShouldUseAbsolutePointerPath(s, 0)); [s mouseMoved:nil]; drain(s); expect(@[@800]);
    hybrid = YES; mouseMode = @"locked";
    assert(![s dispatchVirtualFreeMouseDeltaX:4 deltaY:0 sourceTag:@"raw"]);
    assert(!HIDShouldUseAbsolutePointerPath(s, 0));
    [s mouseMoved:nil]; assert(s.relativeCalls == 1);
    mouseMode = @"remote"; s.useGCMouse = YES;
    assert(![s dispatchVirtualFreeMouseDeltaX:4 deltaY:0 sourceTag:@"raw"]);
    button(s, BUTTON_LEFT, YES, 500); [s mouseMoved:nil];
    assert(s.relativeCalls == 1); drain(s); expect(@[]);
    s.useGCMouse = NO; s.coreHIDMouseRuntimeFailed = YES;
    assert(![s dispatchVirtualFreeMouseDeltaX:4 deltaY:0 sourceTag:@"raw"]);
    assert(HIDShouldUseAbsolutePointerPath(s, 0));
    s.coreHIDMouseRuntimeFailed = NO;
    assert(HIDShouldUseAbsolutePointerPath(s, 1));
    s.precisionTouchpad.suppressed = YES;
    assert([s dispatchVirtualFreeMouseDeltaX:4 deltaY:0 sourceTag:@"raw"]);
    drain(s); expect(@[]);
    puts("PASS: Desktop Sync, locked mouse, GameController, runtime fallback and touchpad isolation");
}
static void concurrentTests(void) {
    HIDSupport *s = support();
    [s updateFreeMouseVirtualCursorAnchorWithViewPoint:NSMakePoint(500, 400) referenceSize:size()];
    dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t i) {
        raw(s, 0.5, 0);
        assert(![s seedFreeMouseVirtualCursorWithViewPoint:NSMakePoint(500, 400) referenceSize:size()]);
    });
    drain(s);
    assert(s.freeMouseVirtualCursorPoint.x == 875);
    int previous = 0;
    for (NSDictionary *p in packets) { assert([p[@"x"] intValue] >= previous); previous = [p[@"x"] intValue]; }
    assert(previous == 7000); [packets removeAllObjects];
    puts("PASS: 1000 concurrent raw callbacks preserve every delta and monotonic output");
}
int main(void) { @autoreleasepool {
    packets = [NSMutableArray array];
    NSString *testCase = @(getenv("POINTER_TEST_CASE") ?: "");
    if (!testCase.length || [testCase isEqual:@"motion"]) motionTests();
    if (!testCase.length || [testCase isEqual:@"queue"]) queueTests();
    if (!testCase.length || [testCase isEqual:@"isolation"]) isolationTests();
    if (!testCase.length || [testCase isEqual:@"concurrent"]) concurrentTests();
} }
