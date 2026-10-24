#import <Foundation/Foundation.h>
#include <assert.h>
#define BUTTON_LEFT 1
#define BUTTON_MIDDLE 2
#define BUTTON_RIGHT 3
#define BUTTON_X1 4
#define BUTTON_X2 5
#define BUTTON_ACTION_PRESS 1
#define BUTTON_ACTION_RELEASE 0
/* MENU GESTURE */
typedef struct { void *connectionContext; BOOL initialized; } Context;
typedef Context *PML_INPUT_STREAM_CONTEXT;
typedef void *PML_CONNECTION_CONTEXT;
static Context contexts[500];
static NSHashTable *supports;
static void LiSetThreadConnectionContext(void *ctx) {}

@interface GCControllerButtonInput : NSObject
@property(copy) void (^pressedChangedHandler)(GCControllerButtonInput *, float, BOOL);
@end
@implementation GCControllerButtonInput
@end
@interface GCControllerAxisInput : NSObject
@property(copy) void (^valueChangedHandler)(GCControllerAxisInput *, float);
@end
@implementation GCControllerAxisInput
@end
@interface Scroll : NSObject
@property(copy) void (^valueChangedHandler)(void);
@property GCControllerAxisInput *yAxis;
@end
@implementation Scroll
@end
@interface GCMouseInput : NSObject
@property(copy) void (^mouseMovedHandler)(GCMouseInput *, float, float);
@property GCControllerButtonInput *leftButton, *middleButton, *rightButton;
@property NSArray<GCControllerButtonInput *> *auxiliaryButtons;
@property Scroll *scroll;
@end
@implementation GCMouseInput
@end
@interface GCMouse : NSObject
@property GCMouseInput *mouseInput;
@end
@implementation GCMouse
@end
@interface Touchpad : NSObject
@property BOOL consumes;
- (void)reset;
@property int consumedCalls;
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed;
@end
@implementation Touchpad
- (void)reset {}
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed {
    assert(button == BUTTON_LEFT || button == BUTTON_RIGHT);
    self.consumedCalls++;
    return self.consumes;
}
@end
@interface Controller : NSObject
@property BOOL isMouseMode;
@property int playerIndex, lastMouseModeButtonFlags;
@property ControllerMenuGesture menuGesture;
@end
@implementation Controller @end
@interface HIDSupport : NSObject {
 BOOL _shouldSendInputEvents;
 void *_inputContext;
}
@property NSMapTable *gcMouseButtonStates;
@property dispatch_queue_t inputQueue;
@property NSObject *inputDiagnosticsLock, *pendingAbsolutePointerBatch, *lastSubmittedAbsolutePointerBatch;
@property uint32_t pressedMouseButtonsMask;
@property uint64_t mouseButtonInputGeneration, mouseButtonContextGeneration;
@property short lastAbsolutePointerReferenceWidth, lastAbsolutePointerReferenceHeight;
@property Controller *controller;
@property int controllerDriver;
@property BOOL gamepadMenuPressed;
- (BOOL)hasPressedMouseButtons;
- (void)releaseAllPressedMouseButtons;
@property BOOL useGCMouse, shouldSendInputEvents;
@property float mouseDeltaX, mouseDeltaY, scrollValue;
@property Touchpad *precisionTouchpad;
@property(nonatomic) void *inputContext;
- (void)handleGCMouseScrollValueY:(float)value;
- (void)registerMouseCallbacks:(GCMouse *)mouse;
- (void)unregisterMouseCallbacks:(GCMouse *)mouse;
@end
static NSMutableArray<NSArray<NSNumber *> *> *packets;
static dispatch_block_t packetHook;
static PML_INPUT_STREAM_CONTEXT HIDInputContext(HIDSupport *support) { return support.inputContext; }
static BOOL HIDValidateInputContext(PML_INPUT_STREAM_CONTEXT ctx, const char *op) { return ctx && ctx->initialized; }
static void LiSendMultiControllerEventCtx(PML_INPUT_STREAM_CONTEXT ctx,int a,int b,int c,int d,int e,int f,int g,int h,int i) {}
static void LiSendMouseButtonEventCtx(PML_INPUT_STREAM_CONTEXT ctx, int action, int button) {
    assert(ctx != NULL);
    __attribute__((objc_precise_lifetime)) dispatch_block_t hook = packetHook;
    packetHook = nil;
    if (hook) hook();
    @synchronized (packets) { [packets addObject:@[@((uintptr_t)ctx), @(action), @(button)]]; }
}

/* PRODUCTION_METHODS */

static GCMouse *device(NSInteger count) {
    GCMouse *mouse = [GCMouse new];
    mouse.mouseInput = [GCMouseInput new];
    mouse.mouseInput.leftButton = [GCControllerButtonInput new];
    mouse.mouseInput.middleButton = [GCControllerButtonInput new];
    mouse.mouseInput.rightButton = [GCControllerButtonInput new];
    if (count >= 0) {
        NSMutableArray *buttons = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) [buttons addObject:[GCControllerButtonInput new]];
        mouse.mouseInput.auxiliaryButtons = [buttons copy];
    }
    mouse.mouseInput.scroll = [Scroll new];
    mouse.mouseInput.scroll.yAxis = [GCControllerAxisInput new];
    return mouse;
}
static HIDSupport *support(uintptr_t context) {
    HIDSupport *s = [HIDSupport new];
    s.inputQueue = dispatch_queue_create("test.gc-buttons", DISPATCH_QUEUE_SERIAL);
    s.inputDiagnosticsLock = [NSObject new];
    s.controller = [Controller new];
    s.controllerDriver = 1;
    s.useGCMouse = YES;
    s.shouldSendInputEvents = YES;
    s.precisionTouchpad = [Touchpad new];
    contexts[context].initialized = YES;
    s.inputContext = &contexts[context];
    [supports addObject:s];
    return s;
}
static void assertHandlers(GCMouse *mouse, BOOL enabled) {
    assert((mouse.mouseInput.mouseMovedHandler != nil) == enabled);
    assert((mouse.mouseInput.leftButton.pressedChangedHandler != nil) == enabled);
    assert((mouse.mouseInput.middleButton.pressedChangedHandler != nil) == enabled);
    assert((mouse.mouseInput.rightButton.pressedChangedHandler != nil) == enabled);
    for (NSUInteger i = 0; i < mouse.mouseInput.auxiliaryButtons.count; i++) {
        assert((mouse.mouseInput.auxiliaryButtons[i].pressedChangedHandler != nil) == (enabled && i < 2));
    }
    assert(mouse.mouseInput.scroll.valueChangedHandler == nil);
    assert((mouse.mouseInput.scroll.yAxis.valueChangedHandler != nil) == (enabled && mouse.mouseInput.scroll != nil));
}
static void drainAll(void) {
    for (HIDSupport *s in supports.allObjects) dispatch_sync(s.inputQueue, ^{});
}
static void emit(GCControllerButtonInput *button, BOOL down) {
    assert(button.pressedChangedHandler != nil);
    button.pressedChangedHandler(button, down ? 1 : 0, down);
}
static void press(GCControllerButtonInput *button, BOOL down) {
    assert(button.pressedChangedHandler != nil);
    button.pressedChangedHandler(button, down ? 1 : 0, down);
    drainAll();
}
static void exerciseButtons(GCMouse *mouse, HIDSupport *s) {
    NSMutableArray *buttons = [NSMutableArray arrayWithArray:@[mouse.mouseInput.leftButton,
                                                              mouse.mouseInput.middleButton,
                                                              mouse.mouseInput.rightButton]];
    NSMutableArray *mapping = [NSMutableArray arrayWithArray:@[@(BUTTON_LEFT), @(BUTTON_MIDDLE), @(BUTTON_RIGHT)]];
    for (NSUInteger i = 0; i < MIN(mouse.mouseInput.auxiliaryButtons.count, 2); i++) {
        [buttons addObject:mouse.mouseInput.auxiliaryButtons[i]];
        [mapping addObject:@(i == 0 ? BUTTON_X1 : BUTTON_X2)];
    }
    [packets removeAllObjects];
    for (NSUInteger i = 0; i < buttons.count; i++) {
        press(buttons[i], YES);
        press(buttons[i], NO);
        assert(([packets[2*i] isEqual:@[@((uintptr_t)s.inputContext), @(BUTTON_ACTION_PRESS), mapping[i]]]));
        assert(([packets[2*i+1] isEqual:@[@((uintptr_t)s.inputContext), @(BUTTON_ACTION_RELEASE), mapping[i]]]));
    }
    assert(packets.count == buttons.count * 2);
    [packets removeAllObjects];
    s.shouldSendInputEvents = NO;
    for (GCControllerButtonInput *button in buttons) { press(button, YES); press(button, NO); }
    assert(packets.count == 0);
    s.shouldSendInputEvents = YES;
    PML_INPUT_STREAM_CONTEXT saved = s.inputContext;
    s.inputContext = NULL;
    for (GCControllerButtonInput *button in buttons) { press(button, YES); press(button, NO); }
    assert(packets.count == 0);
    s.inputContext = saved;
    s.precisionTouchpad.consumes = YES;
    press(mouse.mouseInput.leftButton, YES);
    press(mouse.mouseInput.leftButton, NO);
    press(mouse.mouseInput.rightButton, YES);
    press(mouse.mouseInput.rightButton, NO);
    assert(packets.count == 0);
    s.precisionTouchpad.consumes = NO;
}
static void seedHandlers(GCMouse *mouse) {
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput *input, float x, float y) { assert(NO); };
    for (GCControllerButtonInput *button in @[mouse.mouseInput.leftButton, mouse.mouseInput.middleButton, mouse.mouseInput.rightButton]) {
        button.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { assert(NO); };
    }
    for (GCControllerButtonInput *button in mouse.mouseInput.auxiliaryButtons) {
        button.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { assert(NO); };
    }
    mouse.mouseInput.scroll.valueChangedHandler = ^{ assert(NO); };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput *axis, float value) { assert(NO); };
}
int main(void) { @autoreleasepool {
    packets = [NSMutableArray array];
    supports = [NSHashTable weakObjectsHashTable];
#if RELEASE_REGRESSIONS
    // A real forwarded press must be visible to capture cleanup for every button.
    for (int b = BUTTON_LEFT; b <= BUTTON_X2; b++) {
        HIDSupport *s = support(410); GCMouse *m = device(2);
        [s registerMouseCallbacks:m];
        GCControllerButtonInput *input = @[m.mouseInput.leftButton,m.mouseInput.middleButton,m.mouseInput.rightButton,m.mouseInput.auxiliaryButtons[0],m.mouseInput.auxiliaryButtons[1]][b-1];
        press(input, YES); assert(packets.count == 1);
        assert([s hasPressedMouseButtons]);
        s.shouldSendInputEvents = NO; drainAll();
        assert(packets.count == 2 && [packets.lastObject[1] intValue] == BUTTON_ACTION_RELEASE);
        assert(![s hasPressedMouseButtons]);
        press(input, NO); press(input, YES); assert(packets.count == 2);
        s.shouldSendInputEvents = YES; press(input, NO); assert(packets.count == 2);
        press(input, YES); press(input, NO); assert(packets.count == 4);
        [s unregisterMouseCallbacks:m]; drainAll(); [packets removeAllObjects];
    }
    puts("PASS: all five GCMouse buttons release on pause; paused events and late UP do not leak");
    {
        HIDSupport *s = support(411); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(s.inputQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
        emit(m.mouseInput.leftButton, YES);
        s.shouldSendInputEvents = NO; s.shouldSendInputEvents = YES;
        emit(m.mouseInput.leftButton, YES); emit(m.mouseInput.leftButton, NO);
        dispatch_semaphore_signal(gate); drainAll();
        assert(packets.count == 3);
        assert([packets[0][1] intValue] == BUTTON_ACTION_RELEASE);
        assert([packets[1][1] intValue] == BUTTON_ACTION_PRESS);
        assert([packets[2][1] intValue] == BUTTON_ACTION_RELEASE);
        [s unregisterMouseCallbacks:m]; [packets removeAllObjects];
    }
    puts("PASS: queued old presses cannot survive pause and rapid recapture");
    {
        HIDSupport *s = support(412); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        press(m.mouseInput.leftButton, YES); press(m.mouseInput.rightButton, YES);
        [s releaseAllPressedMouseButtons]; [s releaseAllPressedMouseButtons]; drainAll();
        assert(packets.count == 4 && ![s hasPressedMouseButtons]);
        [s unregisterMouseCallbacks:m]; drainAll(); assert(packets.count == 4);
        [packets removeAllObjects];
    }
    puts("PASS: standalone uncapture and repeated cleanup release each hold exactly once");
    {
        HIDSupport *s = support(413); GCMouse *a = device(2), *b = device(2);
        [s registerMouseCallbacks:a]; [s registerMouseCallbacks:b];
        press(a.mouseInput.leftButton, YES); press(b.mouseInput.leftButton, YES);
        assert(packets.count == 1);
        [s unregisterMouseCallbacks:a]; drainAll(); assert(packets.count == 1 && [s hasPressedMouseButtons]);
        press(b.mouseInput.leftButton, NO); assert(packets.count == 2 && ![s hasPressedMouseButtons]);
        press(b.mouseInput.rightButton, YES); [s unregisterMouseCallbacks:b]; drainAll();
        assert(packets.count == 4 && [packets.lastObject[1] intValue] == BUTTON_ACTION_RELEASE);
        [packets removeAllObjects];
    }
    puts("PASS: disconnect releases only that device; another mouse can keep the same button held");
    {
        HIDSupport *old = support(414), *current = support(415); GCMouse *m = device(2);
        [old registerMouseCallbacks:m];
        void (^stale)(GCControllerButtonInput *,float,BOOL) = m.mouseInput.leftButton.pressedChangedHandler;
        press(m.mouseInput.leftButton, YES);
        [current registerMouseCallbacks:m]; drainAll();
        assert(packets.count == 2 && [packets.lastObject[0] unsignedLongLongValue] == (uintptr_t)old.inputContext);
        stale(m.mouseInput.leftButton, 1, YES); drainAll(); assert(packets.count == 2);
        [old unregisterMouseCallbacks:m]; press(m.mouseInput.leftButton, YES);
        [old releaseAllPressedMouseButtons]; drainAll(); assert(packets.count == 3);
        assert([packets.lastObject[0] unsignedLongLongValue] == (uintptr_t)current.inputContext);
        [current unregisterMouseCallbacks:m]; drainAll(); assert(packets.count == 4);
        stale = nil; [packets removeAllObjects];
    }
    puts("PASS: takeover releases old stream holds; stale callbacks and teardown cannot affect the new stream");
    {
        HIDSupport *s = support(416); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        void (^stale)(GCControllerButtonInput *,float,BOOL) = m.mouseInput.rightButton.pressedChangedHandler;
        press(m.mouseInput.rightButton, YES);
        [s registerMouseCallbacks:m]; drainAll(); assert(packets.count == 2);
        stale(m.mouseInput.rightButton,1,YES); drainAll(); assert(packets.count == 2);
        press(m.mouseInput.rightButton, YES); s.useGCMouse = NO;
        [s registerMouseCallbacks:m]; drainAll(); assert(packets.count == 4);
        assert(![s hasPressedMouseButtons] && m.mouseInput.rightButton.pressedChangedHandler == nil);
        [s unregisterMouseCallbacks:m]; stale = nil; [packets removeAllObjects];
    }
    puts("PASS: re-registration and driver changes release holds and invalidate copied callbacks");
    {
        HIDSupport *s = support(417); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(s.inputQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
        emit(m.mouseInput.leftButton, YES);
        s.inputContext = &contexts[418]; contexts[418].initialized = YES;
        assert(![s hasPressedMouseButtons]); s.inputContext = &contexts[417];
        dispatch_semaphore_signal(gate); drainAll(); assert(packets.count == 0);
        press(m.mouseInput.leftButton, NO); assert(packets.count == 0);
        contexts[417].initialized = NO; press(m.mouseInput.leftButton, YES);
        assert(packets.count == 0 && ![s hasPressedMouseButtons]); contexts[417].initialized = YES;
        s.inputContext = NULL; press(m.mouseInput.leftButton, YES); assert(packets.count == 0);
        [s unregisterMouseCallbacks:m]; [packets removeAllObjects];
    }
    puts("PASS: context replacement and ABA discard queued presses; invalid contexts create no held state");
    {
        HIDSupport *s = support(419); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        Context *retired = calloc(1,sizeof(Context)); retired->initialized = YES; s.inputContext = retired;
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(s.inputQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
        emit(m.mouseInput.leftButton, YES); s.inputContext = &contexts[419]; free(retired);
        dispatch_semaphore_signal(gate); drainAll(); assert(packets.count == 0);
        [s unregisterMouseCallbacks:m];
    }
    puts("PASS: queued GCMouse work never dereferences a detached and freed context");
    {
        HIDSupport *s = support(420); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        s.precisionTouchpad.consumes = YES; press(m.mouseInput.leftButton, YES);
        s.precisionTouchpad.consumes = NO; press(m.mouseInput.leftButton, NO);
        assert(packets.count == 0);
        press(m.mouseInput.leftButton, YES); s.precisionTouchpad.consumes = YES;
        press(m.mouseInput.leftButton, NO); assert(packets.count == 2 && ![s hasPressedMouseButtons]);
        [s unregisterMouseCallbacks:m]; [packets removeAllObjects];
    }
    puts("PASS: touchpad interception cannot swallow release of a previously forwarded press");
    {
        HIDSupport *s = support(421); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(s.inputQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
        emit(m.mouseInput.leftButton,YES); [s unregisterMouseCallbacks:m];
        dispatch_semaphore_signal(gate); drainAll();
        assert(packets.count == 2 && [packets[0][1] intValue] == BUTTON_ACTION_PRESS && [packets[1][1] intValue] == BUTTON_ACTION_RELEASE);
        assert(![s hasPressedMouseButtons]); [packets removeAllObjects];
    }
    puts("PASS: disconnect cleanup stays behind already admitted presses on inputQueue");
    {
        HIDSupport *s = support(422); GCMouse *m = device(2); [s registerMouseCallbacks:m];
        dispatch_semaphore_t entered = dispatch_semaphore_create(0), proceed = dispatch_semaphore_create(0);
        dispatch_semaphore_t pausing = dispatch_semaphore_create(0), paused = dispatch_semaphore_create(0);
        packetHook = ^{
            dispatch_semaphore_signal(entered);
            assert(dispatch_semaphore_wait(proceed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) == 0);
        };
        emit(m.mouseInput.leftButton,YES);
        assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) == 0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            dispatch_semaphore_signal(pausing); s.shouldSendInputEvents = NO; dispatch_semaphore_signal(paused);
        });
        assert(dispatch_semaphore_wait(pausing,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) == 0);
        assert(dispatch_semaphore_wait(paused,dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC)) != 0);
        dispatch_semaphore_signal(proceed);
        assert(dispatch_semaphore_wait(paused,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) == 0);
        drainAll(); assert(packets.count == 2 && [packets.lastObject[1] intValue] == BUTTON_ACTION_RELEASE);
        assert(![s hasPressedMouseButtons]); [s unregisterMouseCallbacks:m]; [packets removeAllObjects];
    }
    puts("PASS: concurrent pause waits for an in-flight send, then releases its button without deadlock");
#endif

    // nil, real empty NSArray, one, two, and more than two auxiliary buttons.
    for (NSInteger count = -1; count <= 4; count++) {
        GCMouse *mouse = device(count);
        HIDSupport *s = support(101 + count);
        [s registerMouseCallbacks:mouse];
        assertHandlers(mouse, YES);
        exerciseButtons(mouse, s);
        mouse.mouseInput.mouseMovedHandler(mouse.mouseInput, 3, 4);
        mouse.mouseInput.scroll.yAxis.valueChangedHandler(mouse.mouseInput.scroll.yAxis, 2);
        assert(s.mouseDeltaX == 3 && s.mouseDeltaY == -4 && s.scrollValue == 2);
        // Cleanup must clear every callback, including extra buttons the sender does not map.
        for (NSUInteger i = 2; i < mouse.mouseInput.auxiliaryButtons.count; i++) {
            mouse.mouseInput.auxiliaryButtons[i].pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { assert(NO); };
        }
        [s unregisterMouseCallbacks:mouse];
        assertHandlers(mouse, NO);
        [s unregisterMouseCallbacks:mouse];
        assertHandlers(mouse, NO);
        seedHandlers(mouse);
        s.useGCMouse = NO;
        [s registerMouseCallbacks:mouse];
        assertHandlers(mouse, NO);
        s.useGCMouse = YES;
        [s registerMouseCallbacks:mouse];
        assertHandlers(mouse, YES);
        [s unregisterMouseCallbacks:mouse];
    }
    puts("PASS: nil/0/1/2/3/4 auxiliary buttons register without exceptions; X1/X2 mappings preserved");
    puts("PASS: all button callbacks preserve input gating, context identity and touchpad interception");
    puts("PASS: movement/scroll forwarding, disabled driver, complete cleanup and re-registration");
    GCMouse *noScroll = device(0);
    noScroll.mouseInput.scroll = nil;
    noScroll.mouseInput.middleButton = nil;
    HIDSupport *s = support(200);
    [s registerMouseCallbacks:noScroll];
    [s unregisterMouseCallbacks:noScroll];
    puts("PASS: absent optional scroll and middle button remain safe");
#if HAS_OWNERS
    for (NSInteger count = -1; count <= 4; count++) {
        GCMouse *shared = device(count), *oldOnly = device(count);
        HIDSupport *old = support(301), *current = support(302);
        [old registerMouseCallbacks:shared];
        [old registerMouseCallbacks:oldOnly];
        [current registerMouseCallbacks:shared];
        [old unregisterMouseCallbacks:shared];
        assertHandlers(shared, YES);
        exerciseButtons(shared, current);
        shared.mouseInput.mouseMovedHandler(shared.mouseInput, 2, -3);
        shared.mouseInput.scroll.yAxis.valueChangedHandler(shared.mouseInput.scroll.yAxis, 7);
        assert(current.mouseDeltaX == 2 && current.mouseDeltaY == 3 && current.scrollValue == 7);
        assert(old.mouseDeltaX == 0 && old.mouseDeltaY == 0 && old.scrollValue == 0);
        [old unregisterMouseCallbacks:oldOnly];
        assertHandlers(oldOnly, NO);
        [current unregisterMouseCallbacks:shared];
        assertHandlers(shared, NO);
    }
    puts("PASS: stale-owner cleanup preserves current callbacks and context for every auxiliary count");
#else
    puts("SKIP: shared-device owner guard is not present on this source branch");
#endif
    __weak HIDSupport *released;
    @autoreleasepool {
        GCMouse *mouse = device(1);
        HIDSupport *temporary = support(400);
        released = temporary;
        [temporary registerMouseCallbacks:mouse];
        [temporary unregisterMouseCallbacks:mouse];
    }
    assert(released == nil);
    puts("PASS: callback cleanup releases HIDSupport");
}}
