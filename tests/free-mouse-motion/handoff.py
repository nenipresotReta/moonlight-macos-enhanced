"""Exercise native-pointer handoff and live-mode transitions without moving a cursor."""
from pathlib import Path
import runpy
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
fixture = runpy.run_path(str(Path(__file__).with_name('run.py')), run_name='pointer_fixture')
source, definition = fixture['source'], fixture['definition']
vc = source('Limelight/macOS/ViewControllers/StreamViewController+MouseCapture.m')
program = fixture['program'].split('int main(void)')[0]
new = '- (void)synchronizeCoreHIDFreeMousePointer' in vc
program += r'''
static BOOL recentRaw = YES;
@interface HIDSupport (Review)
- (BOOL)hasRecentCoreHIDMouseMovement;
- (BOOL)shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration;
@end
@implementation HIDSupport (Review)
- (BOOL)hasRecentCoreHIDMouseMovement { return recentRaw; }
- (BOOL)shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration { return HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self); }
@end
typedef NS_ENUM(NSInteger, MLFreeMouseExitEdge) { MLFreeMouseExitEdgeNone, MLFreeMouseExitEdgeLeft, MLFreeMouseExitEdgeRight, MLFreeMouseExitEdgeTop, MLFreeMouseExitEdgeBottom };
static CGFloat const MLCoreHIDFreeMouseExitThreshold = 1.0;
static int warps;
static CGPoint warpedPoint;
static CGError warpResult;
static CGError ReviewMoveCursor(CGDirectDisplayID display, CGPoint point) { warps++; warpedPoint=point; return warpResult; }
#define CGDisplayMoveCursorToPoint ReviewMoveCursor
static CGFloat MLClampCGFloat(CGFloat value, CGFloat lo, CGFloat hi) { return MIN(MAX(value,lo),hi); }
@interface ReviewWindow:NSObject
@property BOOL isKeyWindow;
@end
@implementation ReviewWindow
@end
@interface ReviewView:NSObject
@property NSRect bounds;
@property ReviewWindow *window;
@end
@implementation ReviewView
@end
@interface ReviewEvent:NSObject
@property id trackingArea;
@end
@implementation ReviewEvent
@end
@interface ReviewStream:NSObject
@property BOOL isRemoteDesktopMode,isMouseCaptured,fullscreen,ownsVirtual;
@property BOOL edgeMenuTemporaryReleaseActive,edgeMenuDragging,edgeMenuMenuVisible,edgeMenuPointerInside;
@property BOOL hasCoreHIDFreeMouseLastTruthPoint,conversionFails;
@property NSPoint coreHIDFreeMouseLastTruthPoint;
@property uint64_t suppressFreeMouseEdgeUncaptureUntilMs;
@property ReviewView *view;
@property HIDSupport *hidSupport;
@property NSPoint systemPoint,exitPoint;
@property MLFreeMouseExitEdge exitEdge;
@property int exits,failures,legacyMouseExits;
@property id edgeMenuButtonTrackingArea;
- (void)synchronizeCoreHIDFreeMousePointer;
@end
'''
if new:
    program += definition(vc, 'static MLFreeMouseExitEdge MLFreeMouseExitEdgeForVirtualPoint')
program += r'''
@implementation ReviewStream
- (BOOL)isWindowFullscreen { return self.fullscreen; }
- (BOOL)isWindowBorderlessMode { return NO; }
- (BOOL)shouldUseCoreHIDTightFreeMouseHandoff { return hybrid; }
- (BOOL)shouldUseCoreHIDVirtualSemanticLocation { return self.ownsVirtual && self.isMouseCaptured && hybrid && recentRaw && ![self.hidSupport.precisionTouchpad shouldSuppressPointerMotion]; }
- (NSPoint)currentMouseLocationInViewCoordinates { return self.systemPoint; }
- (NSPoint)viewPointForMouseEvent:(NSEvent *)e { return self.systemPoint; }
- (BOOL)supportsRemoteDesktopCursorSync { return YES; }
- (BOOL)hasReadyInputContext { return YES; }
- (uint64_t)nowMs { return 1000; }
- (BOOL)hasPressedMouseButtonsForCaptureTransition { return [self.hidSupport hasPressedMouseButtons]; }
- (BOOL)coreGraphicsCursorPointForViewPoint:(NSPoint)p event:(NSEvent *)e exitEdge:(MLFreeMouseExitEdge)edge outDisplayID:(CGDirectDisplayID *)display outPoint:(CGPoint *)point {
    *display=1; *point=NSPointToCGPoint(p); return !self.conversionFails;
}
- (void)uncaptureFreeMouseForExitEdge:(MLFreeMouseExitEdge)edge event:(NSEvent *)e syncViewPoint:(NSPoint)p code:(NSString *)c reason:(NSString *)r {
    self.exits++; self.exitPoint=p; self.exitEdge=edge; self.isMouseCaptured=NO;
}
- (void)uncaptureMouseWithCode:(NSString *)c reason:(NSString *)r { self.failures++; self.isMouseCaptured=NO; }
- (void)updateCoreHIDFreeMouseTruthPointFromEvent:(NSEvent *)e {}
- (void)updateEdgeMenuPointerInsideForPoint:(NSPoint)p {}
- (void)scheduleEdgeMenuAutoCollapse {}
- (void)logControlOrbStateWithReason:(NSString *)r {}
'''
for method in ['- (BOOL)currentCoreHIDVirtualCursorPoint:', '- (NSPoint)boundaryInteractionViewPointForMouseEvent:',
               '- (MLFreeMouseExitEdge)freeMouseExitEdgeForOutsideViewPoint:', '- (MLFreeMouseExitEdge)freeMouseExitEdgeForEvent:',
               '- (BOOL)shouldUncaptureFreeMouseForComputedExitEdge:']:
    program += '\n' + definition(vc, method)
if new:
    program += '\n' + definition(vc, '- (void)reconcileHybridFreeMouseAnchorToCurrentPointer')
    program += '\n' + definition(vc, '- (void)synchronizeCoreHIDFreeMousePointer')
else:
    program += '\n- (void)reconcileHybridFreeMouseAnchorToCurrentPointer {}\n- (void)synchronizeCoreHIDFreeMousePointer {}\n'
# Execute the production tracking-exit routing prefix; replace only the legacy body.
exited = definition(vc, '- (void)mouseExited:')
program += '\n' + exited[:exited.index('    self.isMouseInsideView = NO;')] + '    self.legacyMouseExits++;\n}\n@end\n'
program += r'''
static ReviewStream *stream(HIDSupport *s) {
    ReviewStream *c=[ReviewStream new]; c.hidSupport=s; c.view=[ReviewView new]; c.view.window=[ReviewWindow new];
    c.view.window.isKeyWindow=YES; c.view.bounds=NSMakeRect(0,0,2000,1200);
    c.isRemoteDesktopMode=YES; c.isMouseCaptured=YES; c.fullscreen=YES; c.ownsVirtual=YES;
    c.edgeMenuButtonTrackingArea=[NSObject new]; return c;
}
static void anchor(HIDSupport *s, double x, double y) {
    [s updateFreeMouseVirtualCursorAnchorWithViewPoint:NSMakePoint(x,y) referenceSize:size()];
}
static void modeTest(void) {
    HIDSupport *s=support(); hybrid=NO; anchor(s,500,400);
    [s mouseMoved:nil]; drain(s); hybrid=YES;
    [s refreshMouseInputConfiguration];
    assert(!s.freeMouseVirtualCursorHasAnchor);
    [s seedFreeMouseVirtualCursorWithViewPoint:NSMakePoint(100,400) referenceSize:size()];
    raw(s,4,0); drain(s); assert(s.freeMouseVirtualCursorPoint.x==103);
    puts("PASS: Desktop Sync -> raw mode discards the stale x=500 anchor and continues from x=100");
}
static void handoffTest(void) {
    HIDSupport *s=support(); ReviewStream *c=stream(s); anchor(s,1500,400); raw(s,4,0);
    c.systemPoint=NSMakePoint(2001,400);
    assert([c freeMouseExitEdgeForEvent:nil]==MLFreeMouseExitEdgeNone);
    assert([c boundaryInteractionViewPointForMouseEvent:nil].x==1503);
    [c synchronizeCoreHIDFreeMousePointer]; assert(c.exits==0 && warps==1 && warpedPoint.x==1503);
    ReviewEvent *e=[ReviewEvent new]; [c mouseExited:(NSEvent *)e];
    assert(c.legacyMouseExits==0 && c.exits==0);
    puts("PASS: an accelerated system-pointer exit cannot release a remote cursor still inside");

    anchor(s,1999,400); raw(s,4,0); c.systemPoint=NSMakePoint(1500,400);
    assert([c freeMouseExitEdgeForEvent:nil]==MLFreeMouseExitEdgeRight);
    s.pressedMouseButtonsMask=1; int oldWarps=warps;
    [c synchronizeCoreHIDFreeMousePointer]; assert(c.exits==0 && warps==oldWarps+1 && warpedPoint.x==1999.5);
    s.pressedMouseButtonsMask=0; [c synchronizeCoreHIDFreeMousePointer];
    assert(c.exits==1 && c.exitEdge==MLFreeMouseExitEdgeRight && c.exitPoint.x==2000);
    puts("PASS: remote edge owns handoff; dragging stays captured and releases at the correct edge");

    c.isMouseCaptured=YES; c.fullscreen=NO; anchor(s,1,400); raw(s,-4,0);
    assert([c freeMouseExitEdgeForEvent:nil]==MLFreeMouseExitEdgeLeft);
    anchor(s,500,1199); raw(s,0,-4); assert([c freeMouseExitEdgeForEvent:nil]==MLFreeMouseExitEdgeTop);
    anchor(s,500,1); raw(s,0,4); assert([c freeMouseExitEdgeForEvent:nil]==MLFreeMouseExitEdgeBottom);
    c.suppressFreeMouseEdgeUncaptureUntilMs=2000; [c synchronizeCoreHIDFreeMousePointer]; assert(c.exits==1);
    c.suppressFreeMouseEdgeUncaptureUntilMs=0;
    c.ownsVirtual=NO; oldWarps=warps; [c synchronizeCoreHIDFreeMousePointer]; assert(warps==oldWarps);
    c.ownsVirtual=YES; recentRaw=NO; anchor(s,500,400); c.systemPoint=NSMakePoint(100,400);
    [c reconcileHybridFreeMouseAnchorToCurrentPointer]; drain(s); assert(s.freeMouseVirtualCursorPoint.x==100);
    [c synchronizeCoreHIDFreeMousePointer]; assert(warps==oldWarps); recentRaw=YES;
    puts("PASS: windowed/four-edge behavior, entry suppression, inactive-owner and AppKit takeover");

    anchor(s,500,400); raw(s,4,0); c.systemPoint=NSMakePoint(600,400); warpResult=kCGErrorFailure;
    [c synchronizeCoreHIDFreeMousePointer]; assert(c.failures==1 && !c.isMouseCaptured);
    warpResult=kCGErrorSuccess; c.isMouseCaptured=YES; c.conversionFails=YES;
    [c synchronizeCoreHIDFreeMousePointer]; assert(c.failures==2 && !c.isMouseCaptured);
    drain(s); puts("PASS: a failed native-pointer sync releases capture instead of targeting another window");
}
'''
if new:
    program += r'''
static void spin(void) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]]; }
static void scheduledTest(void) {
    HIDSupport *s=support(); __block int calls=0;
    s.freeMouseAbsoluteSyncHandler=^{calls++;};
    for(int i=0;i<1000;i++) [s scheduleCoreHIDFreeMouseAbsoluteSync];
    spin(); assert(calls==1);
    [s scheduleCoreHIDFreeMouseAbsoluteSync]; [s refreshMouseInputConfiguration]; spin(); assert(calls==1);
    [s scheduleCoreHIDFreeMouseAbsoluteSync]; s.shouldSendInputEvents=NO; spin(); assert(calls==1);
    s.shouldSendInputEvents=YES; [s scheduleCoreHIDFreeMouseAbsoluteSync]; hybrid=NO; spin(); assert(calls==1); hybrid=YES;
    [s scheduleCoreHIDFreeMouseAbsoluteSync]; s.precisionTouchpad.suppressed=YES; spin(); assert(calls==1);
    [s scheduleCoreHIDFreeMouseAbsoluteSync]; spin(); assert(calls==1);
    s.precisionTouchpad.suppressed=NO;
    puts("PASS: native work coalesces 1000 reports and cancels on mode reset, release, fallback and touchpad takeover");
}
'''
program += '\nint main(void) { @autoreleasepool { packets=[NSMutableArray array];\n'
if fixture['options'].case != 'handoff':
    program += 'modeTest();\n'
if fixture['options'].case != 'mode':
    program += 'handoffTest();\n'
    if new:
        program += 'scheduledTest();\n'
program += '} }\n'
with tempfile.TemporaryDirectory(prefix='moonlight-handoff-') as tmp:
    p=Path(tmp); (p/'test.m').write_text(program)
    args = ['clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
            '-Wno-unused-parameter', '-Wno-unused-function', '-framework', 'AppKit']
    if os.environ.get('SANITIZE'):
        args += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    subprocess.run(args + [str(p/'test.m'), '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')],check=True)
