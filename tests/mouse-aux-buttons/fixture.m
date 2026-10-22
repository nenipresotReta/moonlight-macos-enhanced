#import <Foundation/Foundation.h>
#include <assert.h>
#define BUTTON_LEFT 1
#define BUTTON_MIDDLE 2
#define BUTTON_RIGHT 3
#define BUTTON_X1 4
#define BUTTON_X2 5
#define BUTTON_ACTION_PRESS 1
#define BUTTON_ACTION_RELEASE 0
typedef void *PML_INPUT_STREAM_CONTEXT;

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
@property int consumedCalls;
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed;
@end
@implementation Touchpad
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed {
    assert(button == BUTTON_LEFT || button == BUTTON_RIGHT);
    self.consumedCalls++;
    return self.consumes;
}
@end
@interface HIDSupport : NSObject
@property BOOL useGCMouse, shouldSendInputEvents;
@property float mouseDeltaX, mouseDeltaY, scrollValue;
@property Touchpad *precisionTouchpad;
@property PML_INPUT_STREAM_CONTEXT inputContext;
- (void)handleGCMouseScrollValueY:(float)value;
- (void)registerMouseCallbacks:(GCMouse *)mouse;
- (void)unregisterMouseCallbacks:(GCMouse *)mouse;
@end
static NSMutableArray<NSArray<NSNumber *> *> *packets;
static PML_INPUT_STREAM_CONTEXT HIDInputContext(HIDSupport *support) { return support.inputContext; }
static void LiSendMouseButtonEventCtx(PML_INPUT_STREAM_CONTEXT ctx, int action, int button) {
    assert(ctx != NULL);
    [packets addObject:@[@((uintptr_t)ctx), @(action), @(button)]];
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
    s.useGCMouse = YES;
    s.shouldSendInputEvents = YES;
    s.precisionTouchpad = [Touchpad new];
    s.inputContext = (void *)context;
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
static void press(GCControllerButtonInput *button, BOOL down) {
    assert(button.pressedChangedHandler != nil);
    button.pressedChangedHandler(button, down ? 1 : 0, down);
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
