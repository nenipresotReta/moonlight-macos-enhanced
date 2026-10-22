#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <assert.h>
#define Log(...) ((void)0)
#define CACurrentMediaTime() 0.0
#define LiGetNegotiatedDynamicHdrFormat() 0
#define LiGetNegotiatedDynamicHdrFallback() 0

typedef struct { BOOL initialized; } InputContext;
typedef InputContext *PML_INPUT_STREAM_CONTEXT;
typedef struct { BOOL videoFecControlSupported; } *PML_CONTROL_STREAM_CONTEXT;
typedef struct { unsigned receivedFrames, decodedFrames, renderedFrames, totalFrames; uint64_t receivedBytes; } VideoStats;
static unsigned ContextReads, InitializedReads, SessionStarts, Mutations, InputRearms, Captures, Notices, DisplayApplies, FrameCompletions;
static BOOL LiInputContextIsInitialized(PML_INPUT_STREAM_CONTEXT ctx) { InitializedReads++; return ctx->initialized; }
static NSMutableArray<dispatch_block_t> *Immediate, *Delayed;
static void Queue(NSMutableArray *queue, dispatch_block_t block) { [queue addObject:[block copy]]; }
static void Drain(NSMutableArray *queue) { NSArray *batch=[queue copy]; [queue removeAllObjects]; for (dispatch_block_t b in batch) b(); }
#define dispatch_async(queue,block) Queue(Immediate, block)
#define dispatch_after(time,queue,block) Queue(Delayed, block)

@interface VideoDecoderRenderer:NSObject
@property BOOL hasPresentedVideo;
@property (copy) dispatch_block_t firstFramePresentedHandler;
@property VideoStats videoStats;
@end
@implementation VideoDecoderRenderer @end
@interface Connection:NSObject { @public InputContext ctx; }
@property BOOL hasTerminated;
@property VideoDecoderRenderer *renderer;
+ (Connection *)currentConnection;
- (void *)inputStreamContext;
- (void *)controlStreamContext;
@end
static Connection *Current;
@implementation Connection
+ (Connection *)currentConnection { return Current; }
- (void *)inputStreamContext { ContextReads++; return &ctx; }
- (void *)controlStreamContext { return NULL; }
@end
@interface FakeInput:NSObject
@property void *inputContext;
@property BOOL shouldSendInputEvents;
@end
@implementation FakeInput @end
@interface FakeHost:NSObject
@property NSString *uuid;
@end
@implementation FakeHost @end
@interface FakeApp:NSObject
@property FakeHost *host;
@property NSString *id;
@property NSString *name;
@end
@implementation FakeApp @end
@interface StreamManager:NSObject
@property Connection *connection;
@end
@implementation StreamManager @end
@interface FakeView:NSView
@property NSString *statusText;
@end
@implementation FakeView @end
@interface SettingsClass:NSObject
+ (NSDictionary *)getSettingsFor:(id)host;
+ (BOOL)showPerformanceOverlayFor:(id)host;
+ (NSInteger)displayModeFor:(id)host;
@end
@implementation SettingsClass
+ (NSDictionary *)getSettingsFor:(id)host { return @{}; }
+ (BOOL)showPerformanceOverlayFor:(id)host { return NO; }
+ (NSInteger)displayModeFor:(id)host { return 1; }
@end
@interface StreamingSessionManager:NSObject
+ (instancetype)shared;
- (void)startStreamingWithHost:(id)h appId:(id)i appName:(id)n windowController:(id)w;
@end
@implementation StreamingSessionManager
+ (instancetype)shared { static id s; return s ?: (s=[self new]); }
- (void)startStreamingWithHost:(id)h appId:(id)i appName:(id)n windowController:(id)w { SessionStarts++; }
@end
@protocol MLStreamScopedCallbackOwner
- (BOOL)isActiveStreamGeneration:(NSUInteger)g;
- (void)connectionStarted;
- (void)stageComplete:(const char *)stageName;
#if SCOPED_START
- (void)connectionStartedForGeneration:(NSUInteger)g connection:(Connection *)c;
- (void)stageComplete:(const char *)stageName forGeneration:(NSUInteger)g connection:(Connection *)c;
#endif
@end
@interface Owner:NSObject <MLStreamScopedCallbackOwner>
@property NSUInteger activeStreamGeneration;
@property BOOL stopStreamInProgress;
@property BOOL replaceDuringValidation;
@property FakeView *view;
@property FakeView *streamView;
@property NSString *pendingAudioPlanNotice;
@property FakeApp *app;
@property StreamManager *streamMan;
@property Connection *clipboardRuntimeConnection;
@property FakeInput *hidSupport;
@property FakeInput *controllerSupport;
@property BOOL waitingForFirstRenderedFrame;
@property NSString *pendingDisconnectSource;
@property uint64_t streamHealthConnectionStartedMs;
@property BOOL reconnectInProgress;
@property BOOL reconnectPreserveFullscreenStateValid;
@property NSInteger reconnectPreservedWindowMode;
@property id overlayContainer;
@property BOOL isMouseCaptured;
@property BOOL clipboardSessionBound;
@property BOOL fullscreenTransitionInProgress;
#if SCOPED_START
- (BOOL)isCurrentStartupConnection:(Connection *)c generation:(NSUInteger)g;
- (void)retryInputBindingForConnection:(Connection *)c generation:(NSUInteger)g remainingAttempts:(NSUInteger)n;
- (void)handleFirstFramePresentedForGeneration:(NSUInteger)g connection:(Connection *)c;
- (void)scheduleInitialRenderedFrameCheckForGeneration:(NSUInteger)g connection:(Connection *)c remainingAttempts:(NSUInteger)n;
#else
- (void)handleFirstFramePresentedForGeneration:(NSUInteger)g;
- (void)scheduleInitialRenderedFrameCheckForGeneration:(NSUInteger)g remainingAttempts:(NSUInteger)n;
#endif
- (BOOL)isClipboardSyncOwner;
- (BOOL)isWindowFullscreen;
- (BOOL)isWindowBorderlessMode;
- (uint64_t)nowMs;
- (void)finishWaitingForFirstRenderedFrameVia:(NSString *)s;
- (void)audioCodecNotice:(NSString *)s;
- (void)showNotification:(NSString *)s forSeconds:(NSTimeInterval)seconds;
- (void)resetClipboardActivationDiagnosticState;
- (void)rearmMouseCaptureIfPossibleWithReason:(NSString *)s;
- (void)startStreamHealthDiagnostics;
- (void)startAdaptiveBitrateIfEnabled;
- (void)startRemoteDisplayScaleForCurrentSession;
- (void)refreshInputDiagnosticsPreference;
- (void)publishSunshineDisplayRuntimeState:(NSString *)s;
- (void)hideReconnectOverlay;
- (void)setupOverlay;
- (NSString *)displayModeDebugName:(NSInteger)m;
- (void)resetEdgeMenuPlacementForNewStreamSession;
- (void)logCurrentWindowStateWithContext:(NSString *)s;
- (void)captureMouse;
- (void)claimClipboardSyncOwnershipIfNeeded;
- (void)activateClipboardBindingIfPossible;
- (void)applyStartupDisplayMode:(NSInteger)m;
@end
@implementation Owner
- (BOOL)isActiveStreamGeneration:(NSUInteger)g {
    BOOL active=g!=0 && g==self.activeStreamGeneration;
    if (self.replaceDuringValidation) { self.replaceDuringValidation=NO; self.activeStreamGeneration++; }
    return active;
}
- (BOOL)isClipboardSyncOwner { return YES; }
- (BOOL)isWindowFullscreen { return NO; }
- (BOOL)isWindowBorderlessMode { return NO; }
- (uint64_t)nowMs { return 1; }
- (void)finishWaitingForFirstRenderedFrameVia:(NSString *)s { FrameCompletions++; Mutations++; self.waitingForFirstRenderedFrame=NO; }
- (void)audioCodecNotice:(NSString *)s { Notices++; Mutations++; }
- (void)showNotification:(NSString *)s forSeconds:(NSTimeInterval)seconds { Notices++; Mutations++; }
- (void)resetClipboardActivationDiagnosticState { Mutations++; }
- (void)rearmMouseCaptureIfPossibleWithReason:(NSString *)s { InputRearms++; Mutations++; }
- (void)startStreamHealthDiagnostics { Mutations++; }
- (void)startAdaptiveBitrateIfEnabled { Mutations++; }
- (void)startRemoteDisplayScaleForCurrentSession { Mutations++; }
- (void)refreshInputDiagnosticsPreference { Mutations++; }
- (void)publishSunshineDisplayRuntimeState:(NSString *)s { Mutations++; }
- (void)hideReconnectOverlay { Mutations++; }
- (void)setupOverlay { Mutations++; }
- (NSString *)displayModeDebugName:(NSInteger)m { return @"Fullscreen"; }
- (void)resetEdgeMenuPlacementForNewStreamSession { Mutations++; }
- (void)logCurrentWindowStateWithContext:(NSString *)s { Mutations++; }
- (void)captureMouse { Captures++; Mutations++; self.isMouseCaptured=YES; }
- (void)claimClipboardSyncOwnershipIfNeeded { Mutations++; }
- (void)activateClipboardBindingIfPossible { Mutations++; }
- (void)applyStartupDisplayMode:(NSInteger)m { DisplayApplies++; Mutations++; }
// OWNER_METHODS
@end
@interface Proxy:NSObject { @public __weak id<MLStreamScopedCallbackOwner> _owner; NSUInteger _generation; }
- (void)connectionStarted;
- (void)stageComplete:(const char *)stageName;
@end
@implementation Proxy
// PROXY_METHODS
@end
static void ResetCounts(void) { ContextReads=InitializedReads=SessionStarts=Mutations=InputRearms=Captures=Notices=DisplayApplies=FrameCompletions=0; }
static Owner *Setup(void) {
    Immediate=[NSMutableArray new]; Delayed=[NSMutableArray new]; ResetCounts();
    Owner *o=[Owner new]; o.activeStreamGeneration=1;
    o.view=[FakeView new]; o.streamView=o.view; o.hidSupport=[FakeInput new]; o.controllerSupport=[FakeInput new];
    o.streamMan=[StreamManager new]; Current=[Connection new]; Current->ctx.initialized=YES;
    Current.renderer=[VideoDecoderRenderer new]; Current.renderer.hasPresentedVideo=YES;
    o.streamMan.connection=Current; o.pendingAudioPlanNotice=@"Audio notice";
    return o;
}
static void Start(Owner *o) { Proxy *p=[Proxy new]; p->_owner=o; p->_generation=1; [p connectionStarted]; }
static void ClearInput(Owner *o) { o.hidSupport.inputContext=NULL; o.controllerSupport.inputContext=NULL; o.hidSupport.shouldSendInputEvents=NO; o.controllerSupport.shouldSendInputEvents=NO; o.clipboardRuntimeConnection=nil; o.isMouseCaptured=NO; }
static void AssertUntouched(Owner *o) {
    assert(SessionStarts==0 && Mutations==0 && ContextReads==0);
    assert(o.hidSupport.inputContext==NULL && o.controllerSupport.inputContext==NULL);
    assert(!o.hidSupport.shouldSendInputEvents && !o.controllerSupport.shouldSendInputEvents);
    assert(o.clipboardRuntimeConnection==nil && !o.isMouseCaptured);
}
int main(void) { @autoreleasepool {
    // Exercise the actual scoped callback and entire connection-start body, including
    // every nested queue hop. All external side effects are recorded rather than run.
    for (unsigned scenario=0; scenario<5; scenario++) {
        Owner *o=Setup(); Start(o); assert(Immediate.count==1);
        if (scenario==0) { o.activeStreamGeneration++; o.stopStreamInProgress=YES; }
        if (scenario==1) { o.activeStreamGeneration++; o.streamMan.connection=[Connection new]; }
        if (scenario==2) { o.streamMan.connection=[Connection new]; }
        if (scenario==3) { Current.hasTerminated=YES; }
        if (scenario==4) { o.streamMan.connection=nil; }
        ResetCounts(); Drain(Immediate); AssertUntouched(o); assert(Delayed.count==0);
    }
    puts("PASS: close, replacement generation, identity mismatch, terminated and missing connections reject queued startup");
    {
        Owner *o=Setup(); o.replaceDuringValidation=YES; Start(o);
        assert(o.activeStreamGeneration==2); ResetCounts(); Drain(Immediate); AssertUntouched(o);
    }
    puts("PASS: proxy carries its original generation across validation-to-dispatch race");
    for (unsigned scenario=0; scenario<4; scenario++) {
        Owner *o=Setup(); Proxy *p=[Proxy new]; p->_owner=o; p->_generation=1;
        [p stageComplete:"input stream establishment"]; assert(Immediate.count==1);
        if (scenario==0) { o.activeStreamGeneration++; o.stopStreamInProgress=YES; }
        if (scenario==1) { o.streamMan.connection=[Connection new]; }
        if (scenario==2) { Current.hasTerminated=YES; }
        ResetCounts(); Drain(Immediate);
        if (scenario<3) AssertUntouched(o);
        else { assert(o.hidSupport.inputContext==&Current->ctx && o.hidSupport.shouldSendInputEvents && InputRearms==1); }
    }
    puts("PASS: input-stage completion follows the same connection identity guard and still binds the current stream");
    {
        Owner *o=Setup(); Start(o); Drain(Immediate);
        assert(SessionStarts==1 && o.hidSupport.shouldSendInputEvents && o.controllerSupport.shouldSendInputEvents);
        assert(o.hidSupport.inputContext==&Current->ctx && o.controllerSupport.inputContext==&Current->ctx);
        assert(o.clipboardRuntimeConnection==Current && Captures==1 && FrameCompletions==1);
        Drain(Delayed); assert(Notices==1 && DisplayApplies==1);
    }
    puts("PASS: current connection starts normally, binds input, publishes first frame and applies delayed UI");
    for (unsigned scenario=0; scenario<3; scenario++) {
        Owner *o=Setup(); Current->ctx.initialized=NO; Current.renderer.hasPresentedVideo=NO;
        Start(o); Drain(Immediate); assert(Delayed.count>0);
        dispatch_block_t oldFrame=Current.renderer.firstFramePresentedHandler;
        oldFrame(); // The renderer notification itself can already be waiting on main.
        if (scenario==0) { o.activeStreamGeneration++; o.stopStreamInProgress=YES; }
        if (scenario==1) { o.streamMan.connection=[Connection new]; }
        if (scenario==2) { Current.hasTerminated=YES; }
        ClearInput(o); Current->ctx.initialized=YES; Current.renderer.hasPresentedVideo=YES;
        ResetCounts(); Drain(Delayed); Drain(Immediate); AssertUntouched(o);
        assert(InitializedReads==0 && Delayed.count==0 && FrameCompletions==0);
    }
    puts("PASS: delayed binding, first-frame poll/notification, clipboard, audio, display and capture cannot revive old startup");
    {
        Owner *o=Setup(); Current->ctx.initialized=NO; Start(o); Drain(Immediate);
        assert(InputRearms==0); Current->ctx.initialized=YES; Drain(Delayed); assert(InputRearms==1);
    }
    puts("PASS: a current connection still retries until its input context initializes");
    {
        Owner *o=Setup(); Current->ctx.initialized=NO; Start(o); Drain(Immediate);
        for (unsigned i=0; i<25; i++) Drain(Delayed);
        assert(Delayed.count==0 && InputRearms==0);
    }
    puts("PASS: uninitialized input retries remain bounded");
    Immediate=nil; Delayed=nil; Current=nil;
} return 0; }
