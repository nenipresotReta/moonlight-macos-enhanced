#import <Foundation/Foundation.h>
#include <assert.h>
#include "ControllerTrackpadGesture.h"
#include "ControllerMenuGesture.h"
#define A_FLAG 1
#define B_FLAG 2
#define SPECIAL_FLAG 4
#define LB_FLAG 8
#define RB_FLAG 16
#define TOUCHPAD_FLAG 32
#define CONTROLLER_SHORTCUT_LEFT_TRIGGER_MARKER 64
#define CONTROLLER_SHORTCUT_RIGHT_TRIGGER_MARKER 128
#define BUTTON_LEFT 1
#define BUTTON_RIGHT 3
#define BUTTON_ACTION_PRESS 1
#define BUTTON_ACTION_RELEASE 2
#define LI_MOTION_TYPE_GYRO 2
#define HIDGamepadQuitNotification @"test-quit"
#define Log(...) ((void)0)
typedef struct { BOOL initialized; } Context;
typedef Context *PML_INPUT_STREAM_CONTEXT;
static Context context = {YES};
static unsigned contextLookups, shortcutEvaluations;
static NSMutableArray *packets;
static dispatch_semaphore_t enteredPress, allowPress;
static void LiSendMouseButtonEventCtx(Context *p, int action, int button) {
    if (action == BUTTON_ACTION_PRESS && enteredPress) {
        dispatch_semaphore_signal(enteredPress);
        assert(dispatch_semaphore_wait(allowPress, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 5)) == 0);
    }
    @synchronized(packets) { [packets addObject:@[@"mouse", @(action), @(button)]]; }
}
static BOOL LiInputContextIsInitialized(Context *p) { return p && p->initialized; }
static void LiSendControllerMotionEventCtx(Context *p, int a,int b,float c,float d,float e) {
    [packets addObject:@[@"gyro", @(c), @(d), @(e)]];
}
static void LiSendMultiControllerEventCtx(Context *p,int a,int b,int c,int d,int e,int f,int g,int h,int i) {
    [packets addObject:@[@"gamepad", @(c), @(d), @(e), @(f), @(g), @(h), @(i)]];
}
static void LiSendControllerEventCtx(Context *p,int a,int b,int c,int d,int e,int f,int g) {
    LiSendMultiControllerEventCtx(p, 0, 1, a,b,c,d,e,f,g);
}
static unsigned ControllerShortcutProtocolMask(unsigned x) { return x; }
static unsigned ControllerShortcutRouteConsumed(uint64_t x) { return (unsigned)x; }
static unsigned ControllerShortcutRouteReplay(uint64_t x) { return 0; }
static BOOL ControllerShortcutRouteTouchpad(uint64_t x) { return NO; }
@interface Button:NSObject
@property BOOL pressed;
@property float value;
@end
@implementation Button @end
@interface Stick:NSObject
@property Button *xAxis, *yAxis;
@end
@implementation Stick @end
@interface GCExtendedGamepad:NSObject
@property Button *buttonA,*buttonB,*buttonMenu;
@property Stick *rightThumbstick;
@end
@implementation GCExtendedGamepad @end
@interface Gamepad:NSObject
@property GCExtendedGamepad *extendedGamepad;
@end
@implementation Gamepad @end
@interface Controller:NSObject
@property Gamepad *gamepad;
@property BOOL isMouseMode,hasSentGamepadState,controllerAnnounced;
@property unsigned lastMouseModeButtonFlags;
@property uint64_t clientShortcutRouting;
@property int lastButtonFlags,playerIndex,gyroReportRateHz,trackpadMouseButton;
@property unsigned char lastLeftTrigger,lastRightTrigger;
@property short lastLeftStickX,lastLeftStickY,lastRightStickX,lastRightStickY;
@property ControllerMenuGesture menuGesture;
@property ControllerGamepadState sentGamepadState;
@end
@implementation Controller @end
static void ResetControllerTrackpadMouseState(Controller *c) { c.trackpadMouseButton = 0; }
@interface Touchpad:NSObject
- (void)releaseAll;
@end
@implementation Touchpad
- (void)releaseAll {}
@end
@interface ControllerSupport:NSObject {
 BOOL _shouldSendInputEvents,_multiController;
 Touchpad *_dualSenseTouchpad;
 NSMutableDictionary *_controllers;
 NSLock *_controllerStreamLock;
 int _controllerNumbers;
 float _accumulatedMouseX,_accumulatedMouseY;
}
@property(nonatomic) BOOL shouldSendInputEvents;
@property Context *inputContext;
@property uint64_t (^controllerShortcutHandler)(unsigned short, unsigned);
- (void)addController:(Controller *)c;
- (void)receive:(Controller *)limeController gamepad:(GCExtendedGamepad *)gamepad;
- (void)updateFinished:(Controller *)c;
- (void)setGamepadMouseModeActive:(BOOL)active forController:(Controller *)controller;
@end
static Context *ControllerInputContext(ControllerSupport *s) { contextLookups++;return s.inputContext; }
@implementation ControllerSupport
@synthesize shouldSendInputEvents = _shouldSendInputEvents;
- (instancetype)init { self=[super init]; _controllers=[NSMutableDictionary dictionary]; _controllerStreamLock=[NSLock new]; self.inputContext=&context; return self; }
- (void)addController:(Controller *)c { _controllers[@(c.playerIndex)] = c; }
+ (unsigned)getConnectedGamepadMask:(id)unused { return 1; }
- (uint64_t)evaluateControllerShortcuts:(Controller *)c { shortcutEvaluations++;return c.clientShortcutRouting; }
- (void)updateRightStick:(Controller *)c x:(short)x y:(short)y { c.lastRightStickX=x; c.lastRightStickY=y; }
/* METHODS */
- (void)receive:(Controller *)limeController gamepad:(GCExtendedGamepad *)gamepad {
/* CALLBACK */
}
@end
static Controller *makeController(ControllerSupport *s) {
 Controller *c=[Controller new]; c.controllerAnnounced=YES; c.isMouseMode=YES; c.gamepad=[Gamepad new];
 GCExtendedGamepad *g=[GCExtendedGamepad new]; g.buttonA=[Button new];g.buttonB=[Button new];g.buttonMenu=[Button new];
 g.rightThumbstick=[Stick new];g.rightThumbstick.xAxis=[Button new];g.rightThumbstick.yAxis=[Button new];
 c.gamepad.extendedGamepad=g;[s addController:c];return c;
}
static NSArray *mousePackets(void) {
 return [packets filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *p, NSDictionary *bindings) { return [p[0] isEqual:@"mouse"]; }]];
}
int main(void) { @autoreleasepool {
 packets=[NSMutableArray array]; ControllerSupport *s=[ControllerSupport new];Controller *c=makeController(s);GCExtendedGamepad *g=c.gamepad.extendedGamepad;
 g.buttonA.pressed=YES;g.buttonB.pressed=YES;contextLookups=0;[s receive:c gamepad:g];assert(contextLookups==0);assert(mousePackets().count==0); assert(c.lastMouseModeButtonFlags==0);
 s.shouldSendInputEvents=YES; assert(mousePackets().count==2);assert(c.lastMouseModeButtonFlags==(A_FLAG|B_FLAG));
 [s receive:c gamepad:g];assert(mousePackets().count==2);
 c.trackpadMouseButton=5;c.gyroReportRateHz=120;s.shouldSendInputEvents=NO;
 assert(mousePackets().count==5);assert(c.lastMouseModeButtonFlags==0);assert(c.trackpadMouseButton==0);
 assert([mousePackets()[2][1] intValue]==BUTTON_ACTION_RELEASE && [mousePackets()[3][1] intValue]==BUTTON_ACTION_RELEASE);
 NSUInteger paused=packets.count;g.buttonA.pressed=NO;g.buttonB.pressed=NO;[s receive:c gamepad:g];g.buttonA.pressed=YES;[s receive:c gamepad:g]; assert(packets.count==paused);
 s.shouldSendInputEvents=YES;assert([mousePackets().lastObject[1] intValue]==BUTTON_ACTION_PRESS);g.buttonA.pressed=NO;[s receive:c gamepad:g]; assert([mousePackets().lastObject[1] intValue]==BUTTON_ACTION_RELEASE);
 puts("PASS GameController: pause gates A/B, releases held mouse/touchpad, and resume resamples buttons");
 c.clientShortcutRouting=A_FLAG;g.buttonA.pressed=YES;paused=mousePackets().count;[s receive:c gamepad:g]; assert(mousePackets().count==paused);g.buttonB.pressed=YES;[s receive:c gamepad:g];assert([mousePackets().lastObject[2] intValue]==BUTTON_RIGHT);
 s.inputContext=NULL;s.shouldSendInputEvents=NO;assert(c.lastMouseModeButtonFlags==0);s.shouldSendInputEvents=YES;[s receive:c gamepad:g];assert(c.lastMouseModeButtonFlags==0);
 s.inputContext=&context;context.initialized=NO;[s receive:c gamepad:g];assert(c.lastMouseModeButtonFlags==0);context.initialized=YES;[s receive:c gamepad:g];assert(c.lastMouseModeButtonFlags==B_FLAG);
 puts("PASS GameController: shortcut consumption and invalid-context recovery");
 s.shouldSendInputEvents=NO;[s setGamepadMouseModeActive:NO forController:c];paused=mousePackets().count;[s receive:c gamepad:g];assert(mousePackets().count==paused);
 c.clientShortcutRouting=0;c.lastButtonFlags=A_FLAG;c.lastLeftTrigger=123;c.lastRightTrigger=45;c.lastLeftStickX=1234;c.lastRightStickY=-2000;
 shortcutEvaluations=0;s.shouldSendInputEvents=YES;assert(shortcutEvaluations==1);NSArray *state=packets.lastObject;assert([state[0] isEqual:@"gamepad"] && [state[1] intValue]==A_FLAG && [state[2] intValue]==123 && [state[7] intValue]==-2000);
 paused=packets.count;[s updateFinished:c];assert(packets.count==paused);c.lastButtonFlags|=B_FLAG;[s updateFinished:c];assert([packets.lastObject[1] intValue]==(A_FLAG|B_FLAG));
 puts("PASS GameController: paused mode switch preserves normal gamepad state and duplicate suppression");
 [s setGamepadMouseModeActive:YES forController:c];g.buttonA.pressed=YES;g.buttonB.pressed=NO;
 enteredPress=dispatch_semaphore_create(0);allowPress=dispatch_semaphore_create(0);dispatch_group_t group=dispatch_group_create();
 dispatch_group_async(group,dispatch_get_global_queue(0,0),^{[s receive:c gamepad:g];});
 assert(dispatch_semaphore_wait(enteredPress,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC*5))==0);
 dispatch_group_async(group,dispatch_get_global_queue(0,0),^{s.shouldSendInputEvents=NO;});
 dispatch_semaphore_signal(allowPress);assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC*5))==0);
 enteredPress=nil;allowPress=nil;assert([mousePackets().lastObject[1] intValue]==BUTTON_ACTION_RELEASE);assert(c.lastMouseModeButtonFlags==0);
 [s receive:c gamepad:g];assert([mousePackets().lastObject[1] intValue]==BUTTON_ACTION_RELEASE);
 puts("PASS GameController: in-flight press completes before pause release without lock inversion");
 g.buttonA.pressed=YES;[s receive:c gamepad:g];g.buttonA.pressed=NO;[s receive:c gamepad:g];paused=mousePackets().count;s.shouldSendInputEvents=YES;assert(mousePackets().count==paused);
 s.shouldSendInputEvents=NO;c.clientShortcutRouting=A_FLAG;g.buttonA.pressed=YES;[s receive:c gamepad:g];paused=mousePackets().count;s.shouldSendInputEvents=YES;assert(mousePackets().count==paused);
 [s setGamepadMouseModeActive:NO forController:c];contextLookups=0;[s receive:c gamepad:g];assert(contextLookups==0);
 puts("PASS GameController: released or consumed holds do not replay; normal-mode callback does not touch mouse context");
 }}
