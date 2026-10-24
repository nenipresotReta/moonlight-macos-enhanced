#import <Foundation/Foundation.h>
#include <assert.h>
#include "ControllerMenuGesture.h"
#define A_FLAG 1
#define B_FLAG 2
#define PLAY_FLAG 4
#define BACK_FLAG 8
#define LB_FLAG 16
#define RB_FLAG 32
#define BUTTON_LEFT 1
#define BUTTON_MIDDLE 2
#define BUTTON_RIGHT 3
#define BUTTON_X1 4
#define BUTTON_X2 5
#define BUTTON_ACTION_PRESS 1
#define BUTTON_ACTION_RELEASE 2
#define HIDGamepadQuitNotification @"test-quit"
#define HIDMouseModeToggledNotification @"test-mode"
#define Log(...) ((void)0)
typedef struct { BOOL initialized; void *connectionContext; } Context;
typedef Context *PML_INPUT_STREAM_CONTEXT;
static Context context = {YES,NULL};
static unsigned contextLookups;
static NSMutableArray *packets;
static void LiSendMouseButtonEventCtx(Context *p,int action,int button) {
    [packets addObject:@[@"mouse",@(action),@(button)]];
}
static void LiSendMultiControllerEventCtx(Context *p,int a,int b,int c,int d,int e,int f,int g,int h,int i) {
    [packets addObject:@[@"gamepad", @(c)]];
}
static void LiSetThreadConnectionContext(void *ctx) {}
static unsigned ControllerShortcutProtocolMask(unsigned x) { return x; }
static unsigned ControllerShortcutRouteConsumed(uint64_t x) { return (unsigned)x; }
static uint32_t HIDMouseButtonBitForButton(int button) { return 1u << button; }
@interface Controller:NSObject
@property int playerIndex,lastMouseModeButtonFlags,lastButtonFlags,trackpadMouseButton;
@property BOOL isMouseMode,primaryTouchActive,secondaryTouchActive;
@property float trackpadMouseAccumulatedX,trackpadMouseAccumulatedY,trackpadScrollAccumulatedY;
@property ControllerMenuGesture menuGesture;
@end
@implementation Controller @end
@interface Touchpad:NSObject
- (void)reset;
@end
@implementation Touchpad
- (void)reset {}
@end
@interface HIDSupport:NSObject {
 BOOL _shouldSendInputEvents;
}
@property BOOL shouldSendInputEvents;
@property(nonatomic) void *inputContext;
@property NSObject *inputDiagnosticsLock;
@property NSObject *pendingAbsolutePointerBatch, *lastSubmittedAbsolutePointerBatch;
@property short lastAbsolutePointerReferenceWidth,lastAbsolutePointerReferenceHeight;
@property Controller *controller;
@property int controllerDriver;
@property BOOL gamepadMenuPressed;
@property uint32_t controllerShortcutPhysicalButtons,pressedMouseButtonsMask;
@property uint64_t routing,mouseButtonInputGeneration,mouseButtonContextGeneration;
@property dispatch_queue_t inputQueue;
@property Touchpad *precisionTouchpad;
@property id controllerShortcutHandler;
- (void)releaseAllPressedMouseButtons;
- (void)updateButtonFlags:(int)flag state:(BOOL)set;
- (void)setGamepadMouseModeActive:(BOOL)active;
@end
static Context *HIDInputContext(HIDSupport *s) { contextLookups++;return s.inputContext; }
static BOOL HIDValidateInputContext(Context *p,const char *unused) { return p && p->initialized; }
static void HIDDispatchInput(HIDSupport *s,Context *p,dispatch_block_t block) { dispatch_async(s.inputQueue,block); }
/* DISPATCH */
@implementation HIDSupport
- (uint32_t)gcMousePressedButtons { return 0; }
- (uint32_t)clearGCMousePressedButtons { return 0; }
@synthesize shouldSendInputEvents=_shouldSendInputEvents;
@synthesize inputContext=_inputContext;
- (instancetype)init { self=[super init]; self.inputDiagnosticsLock=[NSObject new];self.controller=[Controller new];self.controller.isMouseMode=YES; self.inputContext=&context;self.inputQueue=dispatch_queue_create("controller-pause-fixture",DISPATCH_QUEUE_SERIAL);return self; }
- (void)syncScrollTraceDiagnosticsPreferenceToInputContext {}
- (void)releaseAllModifierKeys {}
- (void)rumbleLowFreqMotor:(int)low highFreqMotor:(int)high {}
- (void)recordMouseButtonDiagnosticsAction:(NSString *)action button:(int)button mask:(uint32_t)mask synthetic:(BOOL)synthetic {}
- (void)sendControllerEvent { if (self.shouldSendInputEvents && !self.controller.isMouseMode) { int flags=self.controller.lastButtonFlags;HIDDispatchInput(self,self.inputContext,^{LiSendMultiControllerEventCtx(self.inputContext,0,1,flags,0,0,0,0,0,0);}); } }
- (uint64_t)evaluateControllerShortcuts { return self.routing; }
- (void)updateGamepadMenuGesture {}
/* RELEASE */
/* METHODS */
@end
static void drain(HIDSupport *s) { dispatch_sync(s.inputQueue,^{}); }
static NSArray *mousePackets(void) { return [packets filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *p, NSDictionary *unused) { return [p[0] isEqual:@"mouse"]; }]]; }
int main(void) { @autoreleasepool {
 packets=[NSMutableArray array];HIDSupport *s=[HIDSupport new];
 [s updateButtonFlags:A_FLAG state:YES];[s updateButtonFlags:B_FLAG state:YES];drain(s);assert(mousePackets().count==0 && s.controller.lastMouseModeButtonFlags==0);
 s.shouldSendInputEvents=YES;drain(s);assert(mousePackets().count==2);
 s.shouldSendInputEvents=NO;drain(s);assert(mousePackets().count==4);assert(s.controller.lastMouseModeButtonFlags==0);assert([mousePackets().lastObject[1] intValue]==BUTTON_ACTION_RELEASE);
 NSUInteger count=packets.count;[s updateButtonFlags:A_FLAG state:NO];[s updateButtonFlags:B_FLAG state:NO];[s updateButtonFlags:A_FLAG state:YES];drain(s);assert(packets.count==count);
 s.shouldSendInputEvents=YES;drain(s);assert(mousePackets().count==5);[s updateButtonFlags:A_FLAG state:NO];drain(s);assert(mousePackets().count==6 && [mousePackets().lastObject[1] intValue]==BUTTON_ACTION_RELEASE);
 puts("PASS HID: paused A/B stay local, pause releases, resume restores held physical buttons");
 s.routing=A_FLAG;count=mousePackets().count;[s updateButtonFlags:A_FLAG state:YES];drain(s);assert(mousePackets().count==count);[s updateButtonFlags:B_FLAG state:YES];drain(s);assert([mousePackets().lastObject[2] intValue]==BUTTON_RIGHT);
 s.inputContext=NULL;s.shouldSendInputEvents=NO;assert(s.controller.lastMouseModeButtonFlags==0);s.shouldSendInputEvents=YES;[s updateButtonFlags:A_FLAG state:YES];assert(s.controller.lastMouseModeButtonFlags==0);
 s.inputContext=&context;context.initialized=NO;[s updateButtonFlags:A_FLAG state:YES];assert(s.controller.lastMouseModeButtonFlags==0);context.initialized=YES;[s updateButtonFlags:B_FLAG state:YES];drain(s);assert(s.controller.lastMouseModeButtonFlags==B_FLAG);
 puts("PASS HID: shortcut consumption and invalid-context recovery");
 s.shouldSendInputEvents=NO;drain(s);s.routing=0;[s setGamepadMouseModeActive:NO];count=mousePackets().count;s.shouldSendInputEvents=YES;drain(s);assert(mousePackets().count==count);assert(s.controller.lastButtonFlags==(A_FLAG|B_FLAG));assert([packets.lastObject[1] intValue]==(A_FLAG|B_FLAG));
 [s updateButtonFlags:A_FLAG state:NO];assert(s.controller.lastButtonFlags==B_FLAG);[s setGamepadMouseModeActive:YES];drain(s);
 puts("PASS HID: paused mode switch restores normal gamepad A/B state");
 [s updateButtonFlags:B_FLAG state:NO];drain(s);[packets removeAllObjects];
 dispatch_semaphore_t ready=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
 dispatch_async(s.inputQueue,^{dispatch_semaphore_signal(ready);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);});
 assert(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
 [s updateButtonFlags:A_FLAG state:YES];s.shouldSendInputEvents=NO;s.shouldSendInputEvents=YES;[s updateButtonFlags:A_FLAG state:NO];
 dispatch_semaphore_signal(release);drain(s);
 // The pre-pause press is invalidated, while the new resume press is ordered
 // after cleanup release and has its own matching release.
 assert(mousePackets().count==3);assert([mousePackets()[0][1] intValue]==BUTTON_ACTION_RELEASE);
 assert([mousePackets()[1][1] intValue]==BUTTON_ACTION_PRESS);assert([mousePackets()[2][1] intValue]==BUTTON_ACTION_RELEASE);
 assert(s.controller.lastMouseModeButtonFlags==0);
 puts("PASS HID: blocked input queue cannot replay a pre-pause press after recapture");
 [packets removeAllObjects];s.controllerDriver=1;[s updateButtonFlags:A_FLAG state:YES];drain(s);assert(mousePackets().count==0);
 puts("PASS HID: GameController backend does not also emit raw HID mouse clicks");
 s.controllerDriver=0;[s updateButtonFlags:A_FLAG state:YES];drain(s);assert(s.controller.lastMouseModeButtonFlags==A_FLAG);
 [s releaseAllPressedMouseButtons];drain(s);assert(s.controller.lastMouseModeButtonFlags==0);assert([mousePackets().lastObject[1] intValue]==BUTTON_ACTION_RELEASE);
 [s updateButtonFlags:A_FLAG state:YES];drain(s);assert(s.controller.lastMouseModeButtonFlags==A_FLAG);
 Context replacement={YES,NULL};contextLookups=0;s.inputContext=&replacement;assert(contextLookups==0);assert(s.controller.lastMouseModeButtonFlags==0);
 [s updateButtonFlags:A_FLAG state:YES];drain(s);assert(s.controller.lastMouseModeButtonFlags==A_FLAG);[s updateButtonFlags:A_FLAG state:NO];drain(s);
 assert([mousePackets().lastObject[1] intValue]==BUTTON_ACTION_RELEASE);
 contextLookups=0;[s releaseControllerMouseButtons];assert(contextLookups==0);
 puts("PASS HID: standalone uncapture releases controller buttons; rebind and empty cleanup do not read the old context");
 s.shouldSendInputEvents=NO;[s updateButtonFlags:A_FLAG state:YES];[s updateButtonFlags:A_FLAG state:NO];count=mousePackets().count;s.shouldSendInputEvents=YES;drain(s);assert(mousePackets().count==count);
 s.shouldSendInputEvents=NO;s.routing=A_FLAG;[s updateButtonFlags:A_FLAG state:YES];drain(s);count=mousePackets().count;s.shouldSendInputEvents=YES;drain(s);assert(mousePackets().count==count);
 puts("PASS HID: released or shortcut-consumed paused holds do not replay on resume");
}}
