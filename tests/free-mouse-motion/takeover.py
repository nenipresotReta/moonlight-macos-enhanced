"""Replay complete AppKit movement routes through production HID packet dispatch."""
from pathlib import Path
import os
import runpy
import subprocess
import tempfile

# Reuse the window/cursor fakes without running handoff's test entry point.
fixture = runpy.run_path(str(Path(__file__).with_name('handoff.py')), run_name='handoff_fixture')
source, definition = fixture['source'], fixture['definition']
program, vc = fixture['program'], fixture['vc']
base = source('Limelight/Input/HIDSupport.m')
internal = source('Limelight/Input/HIDSupport_Internal.h')
pointer = source('Limelight/Input/HIDSupport+Pointer.m')

# Unlike the lower-level pointer suite, execute the real relative fallback too.
program = program.replace('@property int relativeCalls;',
                          '@property int relativeCalls;\n@property uint64_t suppressRelativeMouseUntilMs;')
program = program.replace('@implementation HIDSupport\n', '\n'.join([
    definition(internal, 'static inline short HIDScaledRelativeDelta'),
    definition(internal, 'static inline BOOL HIDShouldSuppressRelativeMouse'),
    'static void LiSendMouseMoveEventCtx(InputContext *ctx, short x, short y) { '
    '[packets addObject:@{@"relativeX":@(x), @"relativeY":@(y)}]; }',
    '@implementation HIDSupport\n',
]))
program = program.replace(
    '- (void)dispatchRelativeMouseDeltaX:(CGFloat)x deltaY:(CGFloat)y sourceTag:(NSString *)s { self.relativeCalls++; }',
    '- (void)recordRelativeInputDiagnosticsFrom:(NSString *)s rawDeltaX:(CGFloat)x rawDeltaY:(CGFloat)y '
    'sentDeltaX:(short)sx sentDeltaY:(short)sy suppressed:(BOOL)suppressed {}\n' +
    definition(base, '- (void)dispatchRelativeMouseDeltaX:'))
# Both VC and HID use the production 250 ms recency predicate against a fake driver.
program = program.replace('- (BOOL)hasRecentCoreHIDMouseMovement { return recentRaw; }',
                          definition(base, '- (BOOL)hasRecentCoreHIDMouseMovement'))
program = program.replace('@property int exits,failures,legacyMouseExits;',
                          '@property int exits,failures,legacyMouseExits;\n@property int consumedRoute;\n'
                          '@property BOOL captureBlocked;\n@property (copy) dispatch_block_t beforeDispatch;')
program = program.replace('- (BOOL)hasReadyInputContext { return YES; }',
                          '- (BOOL)hasReadyInputContext { return validContext; }')
program += r'''
@interface ReviewDriver : NSObject
@property double secondsSinceLastMovementEvent;
@end
@implementation ReviewDriver
@end
@interface HIDSupport (Takeover)
- (BOOL)handleAppKitFreeMouseMotionAtViewPoint:(NSPoint)p referenceSize:(NSSize)s;
@end
@implementation HIDSupport (Takeover)
'''
if '- (BOOL)handleAppKitFreeMouseMotionAtViewPoint:' in pointer:
    program += definition(pointer, '- (BOOL)handleAppKitFreeMouseMotionAtViewPoint:')
else:
    program += '- (BOOL)handleAppKitFreeMouseMotionAtViewPoint:(NSPoint)p referenceSize:(NSSize)s { return NO; }\n'
program += r'''
@end
@interface ReviewStream (Takeover)
- (void)mouseMoved:(NSEvent *)e;
- (void)mouseDragged:(NSEvent *)e;
- (void)rightMouseDragged:(NSEvent *)e;
- (void)otherMouseDragged:(NSEvent *)e;
- (void)dispatchFreeMouseMotionEvent:(NSEvent *)e;
@end
@implementation ReviewStream (Takeover)
- (BOOL)canCaptureMouseNow {
    if(self.beforeDispatch) { dispatch_block_t b=self.beforeDispatch; self.beforeDispatch=nil; b(); }
    return self.view.window.isKeyWindow && validContext && !self.captureBlocked;
}
- (BOOL)handleEdgeMenuTemporaryReleaseForEvent:(NSEvent *)e { return self.consumedRoute==1; }
- (BOOL)attemptPendingMouseExitedRecaptureIfNeededForEvent:(NSEvent *)e { return self.consumedRoute==2; }
- (BOOL)recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:(NSEvent *)e { return self.consumedRoute==3; }
- (BOOL)consumePendingHybridRemoteCursorSyncForEvent:(NSEvent *)e reason:(NSString *)r { return self.consumedRoute==4; }
- (void)uncaptureFreeMouseForExitEdge:(MLFreeMouseExitEdge)edge event:(NSEvent *)e code:(NSString *)c reason:(NSString *)r {
    self.exits++; self.exitEdge=edge; self.isMouseCaptured=NO;
}
'''
if '- (void)dispatchFreeMouseMotionEvent:' in vc:
    program += definition(vc, '- (void)dispatchFreeMouseMotionEvent:')
else:
    program += '- (void)dispatchFreeMouseMotionEvent:(NSEvent *)e { [self.hidSupport mouseMoved:e]; }\n'
for name in ['mouseMoved', 'mouseDragged', 'rightMouseDragged', 'otherMouseDragged']:
    program += '\n' + definition(vc, f'- (void){name}:')
program += '\n@end\n'
program += r'''
static void recency(HIDSupport *s, double age) {
    ReviewDriver *d=[ReviewDriver new]; d.secondsSinceLastMovementEvent=age;
    s.coreHIDMouseDriver=d; recentRaw=age<0.25;
}
static ReviewStream *takeoverStream(void) {
    hybrid=YES; mouseMode=@"remote"; touchMode=0; validContext=YES; sensitivity=1;
    HIDSupport *s=support(); recency(s,1.0); anchor(s,100,400);
    ReviewStream *c=stream(s); c.systemPoint=NSMakePoint(110,400); return c;
}
static NSEvent *eventForRoute(int route) {
    const CGEventType types[]={kCGEventMouseMoved,kCGEventLeftMouseDragged,kCGEventRightMouseDragged,kCGEventOtherMouseDragged};
    const CGMouseButton buttons[]={kCGMouseButtonLeft,kCGMouseButtonLeft,kCGMouseButtonRight,kCGMouseButtonCenter};
    CGEventRef cg=CGEventCreateMouseEvent(NULL,types[route],CGPointMake(110,400),buttons[route]);
    CGEventSetIntegerValueField(cg,kCGMouseEventDeltaX,10);
    NSEvent *e=[NSEvent eventWithCGEvent:cg]; CFRelease(cg); assert(e.deltaX==10); return e;
}
static void route(ReviewStream *c,int kind) {
    NSEvent *e=eventForRoute(kind);
    switch(kind) {
        case 0:[c mouseMoved:e]; break;
        case 1:[c mouseDragged:e]; break;
        case 2:[c rightMouseDragged:e]; break;
        case 3:[c otherMouseDragged:e]; break;
        default:abort();
    }
    drain(c.hidSupport);
}
static void assertAbsolute(int x) {
    if(packets.count!=1 || [packets[0][@"x"] intValue]!=x || packets[0][@"relativeX"]!=nil) {
        NSLog(@"Expected exactly one absolute x=%d packet; got %@",x,packets); abort();
    }
    [packets removeAllObjects];
}
static void assertRelative(int x) {
    assert(packets.count==1 && [packets[0][@"relativeX"] intValue]==x && packets[0][@"x"]==nil);
    [packets removeAllObjects];
}
static void takeoverTests(void) {
    for(int kind=0;kind<4;kind++) {
        ReviewStream *c=takeoverStream(); HIDSupport *s=c.hidSupport;
        if(kind) s.pressedMouseButtonsMask=1u<<(kind-1);
        route(c,kind); assertAbsolute(880);
        assert(s.freeMouseVirtualCursorPoint.x==110 && s.freeMouseVirtualCursorPoint.y==400);
        // A later raw report continues from the last delivered trackpad position.
        c.systemPoint=NSMakePoint(120,400); route(c,kind); assertAbsolute(960);
        recency(s,0.0); raw(s,4,0); drain(s); assertAbsolute(984);
        assert(s.freeMouseVirtualCursorPoint.x==123);
        // AppKit's corresponding movement must not duplicate that raw report.
        route(c,kind); assert(packets.count==0 && s.freeMouseVirtualCursorPoint.x==123);
    }
    puts("PASS: move and left/right/other drag send one takeover position and raw resumes from its latest anchor");

    for(double age=0.249;age<0.251;age+=0.001) {
        ReviewStream *c=takeoverStream(); recency(c.hidSupport,age); route(c,0);
        if(age<0.25) { assert(packets.count==0 && c.hidSupport.freeMouseVirtualCursorPoint.x==100); }
        else assertAbsolute(880);
    }
    puts("PASS: production 250 ms recency boundary excludes duplicate AppKit/raw movement");
}
static void admissionTests(void) {
    ReviewStream *c=takeoverStream(); HIDSupport *s=c.hidSupport;
    // A raw report wins immediately before the final VC admission check. The
    // subsequently read AppKit position is stale relative to that report.
    c.beforeDispatch=^{recency(s,0.0); raw(s,4,0);};
    route(c,0); assertAbsolute(824); assert(s.freeMouseVirtualCursorPoint.x==103);

    c=takeoverStream(); s=c.hidSupport;
    dispatch_semaphore_t gate=pauseQueue(s);
    [c mouseMoved:eventForRoute(0)];
    recency(s,0.0); raw(s,4,0);
    resumeQueue(s,gate); expect(@[@880,@904]);
    assert(s.freeMouseVirtualCursorPoint.x==113);
    puts("PASS: raw arriving before takeover prevents rewind; raw arriving after takeover preserves packet order");
}
static void suppressionTests(void) {
    for(int kind=0;kind<4;kind++) {
        for(int gate=0;gate<10;gate++) {
            ReviewStream *c=takeoverStream(); HIDSupport *s=c.hidSupport;
            if(gate==0) s.shouldSendInputEvents=NO;
            if(gate==1) s.precisionTouchpad.suppressed=YES;
            if(gate==2) validContext=NO;
            if(gate==3) { c.isMouseCaptured=NO; s.shouldSendInputEvents=NO; }
            if(gate==4) [s setFreeMouseVirtualCursorActive:NO];
            if(gate==5) c.view.window.isKeyWindow=NO;
            if(gate==6) c.captureBlocked=YES;
            if(gate==7) c.edgeMenuTemporaryReleaseActive=YES;
            if(gate==8) c.edgeMenuDragging=YES;
            if(gate==9) c.edgeMenuMenuVisible=YES;
            NSPoint oldAnchor=s.freeMouseVirtualCursorPoint;
            route(c,kind); assert(packets.count==0 && NSEqualPoints(s.freeMouseVirtualCursorPoint,oldAnchor));
            validContext=YES;
        }
        // Reconciliation occurs before these route gates. It must be side-effect
        // free while raw input is idle, including when no anchor exists yet.
        for(int gate=1;gate<=4;gate++) {
            ReviewStream *c=takeoverStream(); c.consumedRoute=gate;
            route(c,kind); assert(packets.count==0 && c.hidSupport.freeMouseVirtualCursorPoint.x==100);
            [c.hidSupport resetFreeMouseVirtualCursorState];
            route(c,kind); assert(packets.count==0 && !c.hidSupport.freeMouseVirtualCursorHasAnchor);
        }
    }
    puts("PASS: input disable, precision touchpad, invalid context, capture release and consumed routes send no motion");
}
static void isolationRouteTests(void) {
    for(int kind=0;kind<4;kind++) {
        ReviewStream *c=takeoverStream(); hybrid=NO; route(c,kind); assertAbsolute(800);
        c=takeoverStream(); mouseMode=@"locked"; c.isRemoteDesktopMode=NO; route(c,kind); assertRelative(10);
        c=takeoverStream(); c.hidSupport.useGCMouse=YES; route(c,kind); assert(packets.count==0);
        c=takeoverStream(); c.hidSupport.coreHIDMouseRuntimeFailed=YES; route(c,kind); assertAbsolute(800);
        c=takeoverStream(); c.hidSupport.useCoreHIDMouse=NO; route(c,kind); assertRelative(10);
        c=takeoverStream(); touchMode=1; route(c,kind); assertAbsolute(800);
    }
    touchMode=0;
    puts("PASS: complete routes preserve Desktop Sync, locked mouse, GameController, CoreHID failure and touchscreen overrides");
}
int main(void) { @autoreleasepool {
    packets=[NSMutableArray array]; takeoverTests(); admissionTests(); suppressionTests(); isolationRouteTests();
}}
'''
with tempfile.TemporaryDirectory(prefix='moonlight-takeover-') as tmp:
    path = Path(tmp)
    (path / 'test.m').write_text(program)
    args = ['clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
            '-Wno-unused-parameter', '-Wno-unused-function', '-framework', 'AppKit']
    if os.environ.get('SANITIZE'):
        args += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    subprocess.run(args + [str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
