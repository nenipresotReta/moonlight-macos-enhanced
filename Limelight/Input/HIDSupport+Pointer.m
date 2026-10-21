//
//  HIDSupport+Pointer.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import "HIDSupport_Internal.h"

static CGFloat const HIDGCMouseRelativeSpeedDivisor = 2.5;
static CGFloat const HIDCoreHIDFreeMouseBaselineScale = 0.75;

static inline BOOL HIDAbsoluteMousePayloadForEvent(NSEvent *event,
                                                   BOOL clampToBounds,
                                                   short *hostX,
                                                   short *hostY,
                                                   short *referenceWidth,
                                                   short *referenceHeight) {
    NSPoint viewPoint;
    NSSize referenceSize;
    if (!HIDAbsoluteMouseReferenceForEvent(event, &viewPoint, &referenceSize)) {
        return NO;
    }

    return HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                                referenceSize,
                                                clampToBounds,
                                                hostX,
                                                hostY,
                                                referenceWidth,
                                                referenceHeight);
}

static inline CGFloat HIDClampFreeMouseCoordinate(CGFloat value, CGFloat upperBound) {
    if (!isfinite(value)) {
        return 0.0;
    }
    if (!isfinite(upperBound) || upperBound <= 0.0) {
        return 0.0;
    }
    if (value < 0.0) {
        return 0.0;
    }
    if (value > upperBound) {
        return upperBound;
    }
    return value;
}

static inline NSPoint HIDClampFreeMousePoint(NSPoint point, NSSize referenceSize) {
    CGFloat maxX = MAX(0.0, referenceSize.width);
    CGFloat maxY = MAX(0.0, referenceSize.height);
    return NSMakePoint(HIDClampFreeMouseCoordinate(point.x, maxX),
                       HIDClampFreeMouseCoordinate(point.y, maxY));
}

// Each queued batch owns its payload. A click or explicit sync seals the current
// batch, so later raw reports cannot move ahead of that event on inputQueue.
@interface HIDAbsolutePointerBatch : NSObject
@property short x, y, width, height;
@property (nonatomic, copy) NSString *source;
@end
@implementation HIDAbsolutePointerBatch
@end

static BOOL HIDAbsolutePointerBatchMatches(HIDAbsolutePointerBatch *batch,
                                          short x, short y, short width, short height) {
    return batch != nil && batch.x == x && batch.y == y &&
           batch.width == width && batch.height == height;
}

@implementation HIDSupport (Pointer)

- (void)suppressRelativeMouseMotionForMilliseconds:(uint64_t)durationMs {
    if (durationMs == 0) {
        self.suppressRelativeMouseUntilMs = 0;
        return;
    }
    self.suppressRelativeMouseUntilMs = LiGetMillis() + durationMs;
}

- (void)setFreeMouseVirtualCursorActive:(BOOL)active {
    self.freeMouseVirtualCursorRequestedActive = active;
    if (active) {
        return;
    }

    HIDInvalidateCoreHIDFreeMouseAbsoluteSync(self);
    [self resetFreeMouseVirtualCursorState];
}

- (void)resetFreeMouseVirtualCursorState {
    @synchronized (self.freeMouseVirtualCursorLock) {
        self.freeMouseVirtualCursorHasAnchor = NO;
        self.freeMouseVirtualCursorPoint = NSZeroPoint;
        self.freeMouseVirtualCursorReferenceSize = NSZeroSize;
    }
}

- (void)updateFreeMouseVirtualCursorAnchorWithViewPoint:(NSPoint)viewPoint
                                          referenceSize:(NSSize)referenceSize {
    if (!isfinite(viewPoint.x) || !isfinite(viewPoint.y) ||
        !isfinite(referenceSize.width) || !isfinite(referenceSize.height) ||
        referenceSize.width <= 0.0 || referenceSize.height <= 0.0) {
        return;
    }

    @synchronized (self.freeMouseVirtualCursorLock) {
        if (!self.freeMouseVirtualCursorRequestedActive) {
            return;
        }
        self.freeMouseVirtualCursorPoint = HIDClampFreeMousePoint(viewPoint, referenceSize);
        self.freeMouseVirtualCursorReferenceSize = referenceSize;
        self.freeMouseVirtualCursorHasAnchor = YES;
    }
}

- (BOOL)seedFreeMouseVirtualCursorWithViewPoint:(NSPoint)viewPoint
                                referenceSize:(NSSize)referenceSize {
    if (!isfinite(viewPoint.x) || !isfinite(viewPoint.y) ||
        !isfinite(referenceSize.width) || !isfinite(referenceSize.height) ||
        referenceSize.width <= 0.0 || referenceSize.height <= 0.0) {
        return NO;
    }

    @synchronized (self.freeMouseVirtualCursorLock) {
        if (!self.freeMouseVirtualCursorRequestedActive ||
            (self.freeMouseVirtualCursorHasAnchor &&
             NSEqualSizes(self.freeMouseVirtualCursorReferenceSize, referenceSize))) {
            return NO;
        }
        // AppKit positions and raw HID reports arrive independently. Once seeded,
        // raw motion owns this trajectory until handoff, focus regain or resize.
        // A delayed AppKit event must neither rewind it nor recalibrate its gain.
        [self updateFreeMouseVirtualCursorAnchorWithViewPoint:viewPoint referenceSize:referenceSize];
        [self sendAbsoluteMousePositionForViewPoint:self.freeMouseVirtualCursorPoint
                                      referenceSize:referenceSize
                                      clampToBounds:YES];
        return YES;
    }
}

- (BOOL)sendCurrentFreeMouseVirtualCursorPosition {
    @synchronized (self.freeMouseVirtualCursorLock) {
        if (!self.freeMouseVirtualCursorRequestedActive || !self.freeMouseVirtualCursorHasAnchor ||
            !HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self)) {
            return NO;
        }
        [self sendAbsoluteMousePositionForViewPoint:self.freeMouseVirtualCursorPoint
                                      referenceSize:self.freeMouseVirtualCursorReferenceSize
                                      clampToBounds:YES];
        return YES;
    }
}

- (BOOL)getFreeMouseVirtualCursorPoint:(NSPoint *)viewPoint
                         referenceSize:(NSSize *)referenceSize {
    BOOL hasAnchor = NO;
    NSPoint currentPoint = NSZeroPoint;
    NSSize currentReferenceSize = NSZeroSize;

    @synchronized (self.freeMouseVirtualCursorLock) {
        hasAnchor = self.freeMouseVirtualCursorHasAnchor &&
                    self.freeMouseVirtualCursorReferenceSize.width > 0.0 &&
                    self.freeMouseVirtualCursorReferenceSize.height > 0.0;
        if (hasAnchor) {
            currentPoint = self.freeMouseVirtualCursorPoint;
            currentReferenceSize = self.freeMouseVirtualCursorReferenceSize;
        }
    }

    if (!hasAnchor) {
        return NO;
    }

    if (viewPoint != NULL) {
        *viewPoint = currentPoint;
    }
    if (referenceSize != NULL) {
        *referenceSize = currentReferenceSize;
    }
    return YES;
}

- (void)dispatchAbsolutePointerBatch:(HIDAbsolutePointerBatch *)batch
                       inputContext:(PML_INPUT_STREAM_CONTEXT)inputCtx {
    short x, y, width, height;
    NSString *source;
    @synchronized (self.inputDiagnosticsLock) {
        if (self.pendingAbsolutePointerBatch == batch) {
            self.pendingAbsolutePointerBatch = nil;
        }
        x = batch.x;
        y = batch.y;
        width = batch.width;
        height = batch.height;
        source = batch.source;
    }
    if (!self.shouldSendInputEvents ||
        [self.precisionTouchpad shouldSuppressPointerMotion] ||
        !HIDValidateInputContext(inputCtx, "dispatchAbsolutePointerBatch")) {
        @synchronized (self.inputDiagnosticsLock) {
            if (self.lastSubmittedAbsolutePointerBatch == batch) {
                self.lastSubmittedAbsolutePointerBatch = nil;
            }
        }
        return;
    }
    [self recordAbsoluteInputDiagnosticsFrom:source x:x y:y width:width height:height];
    LiSendMousePositionEventCtx(inputCtx, x, y, width, height);
}

- (void)enqueueAbsolutePointerHostX:(short)x
                              hostY:(short)y
                     referenceWidth:(short)width
                    referenceHeight:(short)height
                          sourceTag:(NSString *)source
                          coalesced:(BOOL)coalesced
                       inputContext:(PML_INPUT_STREAM_CONTEXT)inputCtx {
    @synchronized (self.inputDiagnosticsLock) {
        if (!coalesced) {
            self.pendingAbsolutePointerBatch = nil;
        }
        if (HIDAbsolutePointerBatchMatches(self.lastSubmittedAbsolutePointerBatch, x, y, width, height)) {
            if (self.inputDiagnosticsEnabled) {
                self.inputDiagnosticsAbsoluteDuplicateSkips += 1;
            }
            return;
        }

        HIDAbsolutePointerBatch *batch = coalesced ? self.pendingAbsolutePointerBatch : nil;
        BOOL needsDispatch = batch == nil;
        if (needsDispatch) {
            batch = [HIDAbsolutePointerBatch new];
        }
        batch.x = x;
        batch.y = y;
        batch.width = width;
        batch.height = height;
        batch.source = source;
        self.lastSubmittedAbsolutePointerBatch = batch;
        if (coalesced) {
            self.pendingAbsolutePointerBatch = batch;
        }
        if (needsDispatch) {
            // Submit while holding the same lock used to seal batches. Otherwise
            // another producer could enqueue a click before this batch's flush.
            HIDDispatchInput(self, inputCtx, ^{
                [self dispatchAbsolutePointerBatch:batch inputContext:inputCtx];
            });
        }
    }
}

- (void)sendCoalescedAbsoluteMousePositionForViewPoint:(NSPoint)viewPoint
                                         referenceSize:(NSSize)referenceSize
                                         clampToBounds:(BOOL)clampToBounds
                                             sourceTag:(NSString *)sourceTag {
    if (!self.shouldSendInputEvents || [self.precisionTouchpad shouldSuppressPointerMotion]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "sendCoalescedAbsoluteMousePosition")) {
        return;
    }

    short hostX = 0;
    short hostY = 0;
    short referenceWidth = 0;
    short referenceHeight = 0;
    if (!HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                              referenceSize,
                                              clampToBounds,
                                              &hostX,
                                              &hostY,
                                              &referenceWidth,
                                              &referenceHeight)) {
        return;
    }

    [self enqueueAbsolutePointerHostX:hostX hostY:hostY
                       referenceWidth:referenceWidth referenceHeight:referenceHeight
                            sourceTag:sourceTag coalesced:YES inputContext:inputCtx];
}

- (BOOL)dispatchVirtualFreeMouseDeltaX:(double)deltaX
                                deltaY:(double)deltaY
                             sourceTag:(NSString *)sourceTag {
    (void)sourceTag;
    if (!self.freeMouseVirtualCursorRequestedActive ||
        !HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self) ||
        !self.shouldSendInputEvents ||
        !isfinite(deltaX) ||
        !isfinite(deltaY) ||
        (deltaX == 0.0 && deltaY == 0.0)) {
        return NO;
    }

    if ([self.precisionTouchpad shouldSuppressPointerMotion]) {
        // The trackpad is driving the host; report the motion as handled so it is not re-sent as relative motion.
        return YES;
    }

    CGFloat sensitivity = HIDPointerSensitivityForHost(self.host);
    double scaledSensitivity = sensitivity * HIDCoreHIDFreeMouseBaselineScale;
    double viewDeltaX = deltaX * scaledSensitivity;
    double viewDeltaY = -deltaY * scaledSensitivity;

    NSPoint predictedPoint = NSZeroPoint;
    NSSize referenceSize = NSZeroSize;

    @synchronized (self.freeMouseVirtualCursorLock) {
        if (!self.freeMouseVirtualCursorRequestedActive ||
            !self.freeMouseVirtualCursorHasAnchor ||
            self.freeMouseVirtualCursorReferenceSize.width <= 0.0 ||
            self.freeMouseVirtualCursorReferenceSize.height <= 0.0) {
            return NO;
        }

        predictedPoint = self.freeMouseVirtualCursorPoint;
        predictedPoint.x += viewDeltaX;
        predictedPoint.y += viewDeltaY;
        predictedPoint = HIDClampFreeMousePoint(predictedPoint, self.freeMouseVirtualCursorReferenceSize);

        self.freeMouseVirtualCursorPoint = predictedPoint;
        referenceSize = self.freeMouseVirtualCursorReferenceSize;
        // Keep integration and submission atomic across concurrent HID callbacks.
        [self sendCoalescedAbsoluteMousePositionForViewPoint:predictedPoint
                                           referenceSize:referenceSize
                                           clampToBounds:YES
                                               sourceTag:@"sendAbsoluteMousePosition"];
    }
    return YES;
}

-(void)registerMouseCallbacks:(GCMouse *)mouse API_AVAILABLE(macos(11.0)) {
    if (self.useGCMouse) {
        mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
            self.mouseDeltaX += deltaX;
            self.mouseDeltaY -= deltaY;
        };
        
        mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if ([self.precisionTouchpad consumeMouseButton:BUTTON_LEFT pressed:pressed]) {
                return;
            }
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            }
        };
        mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
            }
        };
        mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if ([self.precisionTouchpad consumeMouseButton:BUTTON_RIGHT pressed:pressed]) {
                return;
            }
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
            }
        };
        
        mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
            }
        };
        mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
            }
        };
    } else {
        mouse.mouseInput.mouseMovedHandler = nil;
        mouse.mouseInput.leftButton.pressedChangedHandler = nil;
        mouse.mouseInput.middleButton.pressedChangedHandler = nil;
        mouse.mouseInput.rightButton.pressedChangedHandler = nil;
        for (GCControllerButtonInput *auxButton in mouse.mouseInput.auxiliaryButtons) {
            auxButton.pressedChangedHandler = nil;
        }
    }

    if (mouse.mouseInput.scroll != nil) {
        if (self.useGCMouse) {
            mouse.mouseInput.scroll.valueChangedHandler = nil;
            mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
                (void)axis;
                [self handleGCMouseScrollValueY:value];
            };
        } else {
            mouse.mouseInput.scroll.valueChangedHandler = nil;
            mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
        }
    }
}

-(void)unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(macos(11.0)) {
    mouse.mouseInput.mouseMovedHandler = nil;
    
    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }

    if (mouse.mouseInput.scroll != nil) {
        mouse.mouseInput.scroll.valueChangedHandler = nil;
        mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
    }
}

static CVReturn displayLinkOutputCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp *now,
                                          const CVTimeStamp *vsyncTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags *flagsOut,
                                          void *displayLinkContext)
{
    HIDSupport *me = (__bridge HIDSupport *)displayLinkContext;
    if (me == nil) {
        return kCVReturnError;
    }

    CGFloat deltaX, deltaY;
    deltaX = me.mouseDeltaX;
    deltaY = me.mouseDeltaY;
    if (deltaX != 0 || deltaY != 0) {
        me.mouseDeltaX = 0;
        me.mouseDeltaY = 0;
        if (me.shouldSendInputEvents) {
            PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(me);
            if (!inputCtx) {
                return kCVReturnSuccess;
            }
            NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:me.host.uuid];
            BOOL useAbsolutePointerPath = HIDShouldUseAbsolutePointerPath(me, touchscreenMode);
            if (!useAbsolutePointerPath) {
                BOOL suppressed = HIDShouldSuppressRelativeMouse(me);
                if (suppressed) {
                    [me recordRelativeInputDiagnosticsFrom:@"gcMouse"
                                                 rawDeltaX:deltaX
                                                 rawDeltaY:deltaY
                                                sentDeltaX:0
                                                sentDeltaY:0
                                                suppressed:YES];
                    return kCVReturnSuccess;
                }
                CGFloat normalizedDeltaX = deltaX / HIDGCMouseRelativeSpeedDivisor;
                CGFloat normalizedDeltaY = deltaY / HIDGCMouseRelativeSpeedDivisor;
                CGFloat sensitivity = HIDPointerSensitivityForHost(me.host);
                short moveX = HIDScaledRelativeDelta(normalizedDeltaX, sensitivity);
                short moveY = HIDScaledRelativeDelta(normalizedDeltaY, sensitivity);
                [me recordRelativeInputDiagnosticsFrom:@"gcMouse"
                                             rawDeltaX:deltaX
                                             rawDeltaY:deltaY
                                            sentDeltaX:moveX
                                            sentDeltaY:moveY
                                            suppressed:NO];
                HIDDispatchInput(me, inputCtx, ^{
                    LiSendMouseMoveEventCtx(inputCtx, moveX, moveY);
                });
                [SettingsClass updateMouseInputRuntimeStatusFor:me.host.uuid
                                                    summaryKey:@"Mouse Runtime Path GameController Active"
                                                     detailKey:@"Mouse Runtime Detail GameController Active"];
            }
        }
    }
    
    // Mouse Emulation Movement
    if (me.controller.isMouseMode && me.shouldSendInputEvents) {
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(me);
        if (!inputCtx) {
            return kCVReturnSuccess;
        }
        short rx = me.controller.lastRightStickX;
        short ry = me.controller.lastRightStickY;
        short deadzone = 4000;
        float sensitivity = 15.0f; // Approx match to Qt/ControllerSupport
        
        if (abs(rx) > deadzone || abs(ry) > deadzone) {
            float dx = (float)(abs(rx) > deadzone ? rx : 0) / 32767.0f * sensitivity;
            float dy = (float)(abs(ry) > deadzone ? ry : 0) / 32767.0f * sensitivity;
            
            // Invert Y? Usually stick Y is up=negative or positive depending on driver.
            // HID usage: Y min is top (-32768), max is bottom (32767).
            // Mouse move: +Y is down.
            // So +StickY should be +MouseY.
            // ControllerSupport uses -dy. Let's try direct map first.
            // ControllerSupport: dy = -dy * sens.
            // Let's use -dy for now.
            
            short moveX = (short)dx;
            short moveY = (short)dy; // Try positive first based on HID mapping logic above (MIN(-(val), ...)) inverted already?
            
            // Wait, updateButtonFlags logic:
            // kHIDUsage_GD_Y: self.controller.lastLeftStickY = MIN(-(intValue - 32768), 32767);
            // It inverts it. So Up is Positive?
            // Standard XInput: Up is Positive.
            // Mouse Move: +Y is Down.
            // So Up (+Stick) -> Up (-Mouse).
            // So we need to invert Y.
            
            moveY = (short)(-dy);
            
            [me recordRelativeInputDiagnosticsFrom:@"controllerMouse"
                                         rawDeltaX:dx
                                         rawDeltaY:-dy
                                        sentDeltaX:moveX
                                        sentDeltaY:moveY
                                        suppressed:NO];
            if (moveX != 0 || moveY != 0) {
                HIDDispatchInput(me, inputCtx, ^{
                    LiSendMouseMoveEventCtx(inputCtx, moveX, moveY);
                });
            }
        }
    }

    return kCVReturnSuccess;
}

- (BOOL)initializeDisplayLink
{
    NSNumber *screenNumber = [[NSScreen mainScreen] deviceDescription][@"NSScreenNumber"];

    CGDirectDisplayID displayId = [screenNumber unsignedIntValue];
    CVDisplayLinkRef displayLink;
    CVReturn status = CVDisplayLinkCreateWithCGDisplay(displayId, &displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"Failed to create CVDisplayLink: %d", status);
        return NO;
    }
    self.displayLink = displayLink;
    
    __weak typeof(self) weakSelf = self;
    status = CVDisplayLinkSetOutputCallback(self.displayLink, displayLinkOutputCallback, (__bridge void * _Nullable)(weakSelf));
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkSetOutputCallback() failed: %d", status);
        return NO;
    }
    
    status = CVDisplayLinkStart(self.displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkStart() failed: %d", status);
        return NO;
    }
    
    return YES;
}


- (BOOL)hasPressedMouseButtons {
    return self.pressedMouseButtonsMask != 0;
}

- (void)releaseAllPressedMouseButtons {
    uint32_t pressedMask = self.pressedMouseButtonsMask;
    if (pressedMask == 0) {
        return;
    }

    self.pressedMouseButtonsMask = 0;

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (self.shouldSendInputEvents && HIDValidateInputContext(inputCtx, "releaseAllPressedMouseButtons")) {
        static const int buttons[] = {
            BUTTON_LEFT,
            BUTTON_MIDDLE,
            BUTTON_RIGHT,
            BUTTON_X1,
            BUTTON_X2,
        };

        for (NSUInteger index = 0; index < sizeof(buttons) / sizeof(buttons[0]); index++) {
            int button = buttons[index];
            if ((pressedMask & HIDMouseButtonBitForButton(button)) == 0) {
                continue;
            }

            LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_RELEASE, button);
            [self recordMouseButtonDiagnosticsAction:@"release"
                                              button:button
                                                mask:self.pressedMouseButtonsMask
                                           synthetic:YES];
        }
    }
}

- (void)mouseDown:(NSEvent *)event withButton:(int)button {
    if (self.useGCMouse) {
        return;
    }
    
    if ([SettingsClass swapMouseButtonsFor:self.host.uuid]) {
        if (button == BUTTON_LEFT) {
            button = BUTTON_RIGHT;
        } else if (button == BUTTON_RIGHT) {
            button = BUTTON_LEFT;
        }
    }
    
    if (!self.shouldSendInputEvents) {
        return;
    }

    if ([self.precisionTouchpad consumeMouseButton:button pressed:YES]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "mouseDown")) {
        return;
    }

    self.pressedMouseButtonsMask |= HIDMouseButtonBitForButton(button);
    [self recordMouseButtonDiagnosticsAction:@"press"
                                      button:button
                                        mask:self.pressedMouseButtonsMask
                                   synthetic:NO];
    @synchronized (self.inputDiagnosticsLock) {
        self.pendingAbsolutePointerBatch = nil;
        HIDDispatchInput(self, inputCtx, ^{
            LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_PRESS, button);
        });
    }
}

- (void)mouseUp:(NSEvent *)event withButton:(int)button {
    if (self.useGCMouse) {
        return;
    }
    
    if ([SettingsClass swapMouseButtonsFor:self.host.uuid]) {
        if (button == BUTTON_LEFT) {
            button = BUTTON_RIGHT;
        } else if (button == BUTTON_RIGHT) {
            button = BUTTON_LEFT;
        }
    }
    
    if ([self.precisionTouchpad consumeMouseButton:button pressed:NO]) {
        return;
    }

    if (self.shouldSendInputEvents) {
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
        if (HIDValidateInputContext(inputCtx, "mouseUp")) {
            @synchronized (self.inputDiagnosticsLock) {
                self.pendingAbsolutePointerBatch = nil;
                HIDDispatchInput(self, inputCtx, ^{
                    LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_RELEASE, button);
                });
            }
        }
    }

    self.pressedMouseButtonsMask &= ~HIDMouseButtonBitForButton(button);
    [self recordMouseButtonDiagnosticsAction:@"release"
                                      button:button
                                        mask:self.pressedMouseButtonsMask
                                   synthetic:NO];
}

- (void)mouseMoved:(NSEvent *)event {
    if (!self.shouldSendInputEvents) {
        return;
    }

    if ([self.precisionTouchpad shouldSuppressPointerMotion]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "mouseMoved")) {
        return;
    }

    NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:self.host.uuid];
    BOOL useAbsolutePointerPath = HIDShouldUseAbsolutePointerPath(self, touchscreenMode);

    if (self.useGCMouse && !useAbsolutePointerPath) {
        return;
    }

    if (useAbsolutePointerPath) {
        short hostX = 0;
        short hostY = 0;
        short referenceWidth = 0;
        short referenceHeight = 0;
        if (!HIDAbsoluteMousePayloadForEvent(event,
                                             YES,
                                             &hostX,
                                             &hostY,
                                             &referenceWidth,
                                             &referenceHeight)) {
            return;
        }
        [self enqueueAbsolutePointerHostX:hostX hostY:hostY
                           referenceWidth:referenceWidth referenceHeight:referenceHeight
                                sourceTag:@"mouseMoved" coalesced:NO inputContext:inputCtx];
        [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                            summaryKey:@"Mouse Runtime Path Absolute Active"
                                             detailKey:@"Mouse Runtime Detail Absolute Active"];
    } else {
        if (self.useCoreHIDMouse &&
            self.coreHIDMouseDriver != nil &&
            self.coreHIDMouseDriver.secondsSinceLastMovementEvent < 0.25) {
            return;
        }
        [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                            summaryKey:@"Mouse Runtime Path AppKit Active"
                                             detailKey:@"Mouse Runtime Detail AppKit Active"];
        [self dispatchRelativeMouseDeltaX:event.deltaX
                                   deltaY:event.deltaY
                                sourceTag:@"mouseMoved"];
    }
}

- (void)sendAbsoluteMousePositionForViewPoint:(NSPoint)viewPoint
                                referenceSize:(NSSize)referenceSize
                                clampToBounds:(BOOL)clampToBounds {
    if ([self.precisionTouchpad shouldSuppressPointerMotion]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "sendAbsoluteMousePosition")) {
        return;
    }

    short hostX = 0;
    short hostY = 0;
    short referenceWidth = 0;
    short referenceHeight = 0;
    if (!HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                              referenceSize,
                                              clampToBounds,
                                              &hostX,
                                              &hostY,
                                              &referenceWidth,
                                              &referenceHeight)) {
        return;
    }

    @synchronized (self.freeMouseVirtualCursorLock) {
        // Explicit handoff/focus sync must update the anchor and enter inputQueue
        // together; a raw report must not be submitted between these operations.
        [self updateFreeMouseVirtualCursorAnchorWithViewPoint:viewPoint referenceSize:referenceSize];
        [self enqueueAbsolutePointerHostX:hostX hostY:hostY
                           referenceWidth:referenceWidth referenceHeight:referenceHeight
                                sourceTag:@"sendAbsoluteMousePosition" coalesced:NO inputContext:inputCtx];
    }
}

- (void)sendMouseButton:(int)button
                pressed:(BOOL)pressed
      syncedToViewPoint:(NSPoint)viewPoint
          referenceSize:(NSSize)referenceSize
          clampToBounds:(BOOL)clampToBounds {
    if (self.useGCMouse) {
        return;
    }

    if ([SettingsClass swapMouseButtonsFor:self.host.uuid]) {
        if (button == BUTTON_LEFT) {
            button = BUTTON_RIGHT;
        } else if (button == BUTTON_RIGHT) {
            button = BUTTON_LEFT;
        }
    }

    if (!self.shouldSendInputEvents) {
        return;
    }

    if ([self.precisionTouchpad consumeMouseButton:button pressed:pressed]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, pressed ? "sendMouseButtonPressSynced" : "sendMouseButtonReleaseSynced")) {
        return;
    }

    @synchronized (self.freeMouseVirtualCursorLock) {
        if (self.freeMouseVirtualCursorRequestedActive && self.freeMouseVirtualCursorHasAnchor &&
            HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self) &&
            NSEqualSizes(referenceSize, self.freeMouseVirtualCursorReferenceSize)) {
            viewPoint = self.freeMouseVirtualCursorPoint;
        }
        short hostX = 0;
        short hostY = 0;
        short referenceWidth = 0;
        short referenceHeight = 0;
        BOOL shouldSendAbsolute = HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                                                       referenceSize,
                                                                       clampToBounds,
                                                                       &hostX,
                                                                       &hostY,
                                                                       &referenceWidth,
                                                                       &referenceHeight);
        // A button is a boundary even when its position duplicates the previous one.
        @synchronized (self.inputDiagnosticsLock) {
            self.pendingAbsolutePointerBatch = nil;
            if (shouldSendAbsolute && HIDAbsolutePointerBatchMatches(self.lastSubmittedAbsolutePointerBatch,
                                                                     hostX, hostY, referenceWidth, referenceHeight)) {
                if (self.inputDiagnosticsEnabled) {
                    self.inputDiagnosticsAbsoluteDuplicateSkips += 1;
                }
                shouldSendAbsolute = NO;
            }
            if (shouldSendAbsolute) {
                HIDAbsolutePointerBatch *position = [HIDAbsolutePointerBatch new];
                position.x = hostX;
                position.y = hostY;
                position.width = referenceWidth;
                position.height = referenceHeight;
                self.lastSubmittedAbsolutePointerBatch = position;
            }

            if (pressed) {
                self.pressedMouseButtonsMask |= HIDMouseButtonBitForButton(button);
                [self recordMouseButtonDiagnosticsAction:@"press"
                                                  button:button
                                                    mask:self.pressedMouseButtonsMask
                                               synthetic:NO];
            }

            HIDDispatchInput(self, inputCtx, ^{
                if (shouldSendAbsolute) {
                    [self recordAbsoluteInputDiagnosticsFrom:@"sendAbsoluteMouseButtonSync"
                                                           x:hostX y:hostY width:referenceWidth height:referenceHeight];
                    LiSendMousePositionEventCtx(inputCtx, hostX, hostY, referenceWidth, referenceHeight);
                }
                LiSendMouseButtonEventCtx(inputCtx,
                                          pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE,
                                          button);
            });
        }
    }

    if (!pressed) {
        self.pressedMouseButtonsMask &= ~HIDMouseButtonBitForButton(button);
        [self recordMouseButtonDiagnosticsAction:@"release"
                                          button:button
                                            mask:self.pressedMouseButtonsMask
                                       synthetic:NO];
    }
}

- (BOOL)absoluteMousePayloadForViewPoint:(NSPoint)viewPoint
                           referenceSize:(NSSize)referenceSize
                           clampToBounds:(BOOL)clampToBounds
                                   hostX:(short *)hostX
                                   hostY:(short *)hostY
                          referenceWidth:(short *)referenceWidth
                         referenceHeight:(short *)referenceHeight {
    return HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                                referenceSize,
                                                clampToBounds,
                                                hostX,
                                                hostY,
                                                referenceWidth,
                                                referenceHeight);
}


@end

@implementation HIDSupport (PrecisionTouchpad)

- (void)setUpPrecisionTouchpad {
    MLPrecisionTouchpad *touchpad = [[MLPrecisionTouchpad alloc] init];
    __weak HIDSupport *weakSelf = self;
    touchpad.dispatchHandler = ^(void (^work)(PML_INPUT_STREAM_CONTEXT ctx)) {
        HIDSupport *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(strongSelf);
        if (!HIDValidateInputContext(inputCtx, "precisionTouchpad")) {
            return;
        }
        HIDDispatchInput(strongSelf, inputCtx, ^{
            work(inputCtx);
        });
    };
    touchpad.featureFlagsProvider = ^uint32_t{
        HIDSupport *strongSelf = weakSelf;
        PML_INPUT_STREAM_CONTEXT inputCtx = strongSelf != nil ? (PML_INPUT_STREAM_CONTEXT)strongSelf.inputContext : NULL;
        if (inputCtx == NULL || inputCtx->connectionContext == NULL) {
            return 0;
        }
        return LiGetHostFeatureFlagsCtx(inputCtx->connectionContext);
    };
    self.precisionTouchpad = touchpad;
    [self refreshPrecisionTouchpadConfiguration];
}

- (void)refreshPrecisionTouchpadConfiguration {
    MLPrecisionTouchpadMode mode = MLPrecisionTouchpadModeOff;
    if (self.host.uuid != nil) {
        NSInteger stored = [SettingsClass hostPrecisionTouchpadModeFor:self.host.uuid];
        mode = (stored == MLPrecisionTouchpadModeBlock || stored == MLPrecisionTouchpadModeBoth)
            ? (MLPrecisionTouchpadMode)stored : MLPrecisionTouchpadModeOff;
    }
    self.precisionTouchpad.mode = mode;
}

- (void)handleTrackpadTouchesEvent:(NSEvent *)event inView:(NSView *)view {
    if (!self.shouldSendInputEvents) {
        [self.precisionTouchpad reset];
        return;
    }
    [self.precisionTouchpad handleTouchesEvent:event inView:view];
}

@end
