//
//  MLSystemShortcutCapture.m
//  Moonlight for macOS
//

#import "MLSystemShortcutCapture.h"
#import "MLSystemGestureBlocker.h"
#import "Logger.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

typedef struct {
    CFMachPortRef tap;
    uint64_t captured;
    uint64_t reenabled;
    BOOL loggedFirstCapture;
} MLShortcutTapState;

static BOOL MLIsFunctionKeyCode(int64_t keyCode) {
    switch (keyCode) {
        case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5:
        case kVK_F6: case kVK_F7: case kVK_F8: case kVK_F9: case kVK_F10:
        case kVK_F11: case kVK_F12: case kVK_F13: case kVK_F14: case kVK_F15:
        case kVK_F16: case kVK_F17: case kVK_F18: case kVK_F19: case kVK_F20:
            return YES;
        default:
            return NO;
    }
}

// System shortcuts all carry Command or Control, or sit on a function key.
// Force Quit (⌥⌘Esc) and Lock Screen (⌃⌘Q) stay with macOS so the Mac can
// always be recovered.
static BOOL MLShouldCaptureKeyEvent(CGEventRef event) {
    CGEventFlags flags = CGEventGetFlags(event);
    int64_t keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    BOOL command = (flags & kCGEventFlagMaskCommand) != 0;
    BOOL control = (flags & kCGEventFlagMaskControl) != 0;
    BOOL option = (flags & kCGEventFlagMaskAlternate) != 0;
    if (command && option && keyCode == kVK_Escape) {
        return NO;
    }
    if (command && control && keyCode == kVK_ANSI_Q) {
        return NO;
    }
    return command || control || MLIsFunctionKeyCode(keyCode);
}

static CGEventRef MLSystemShortcutTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    (void)proxy;
    MLShortcutTapState *state = (MLShortcutTapState *)userInfo;
    if (state == NULL) {
        return event;
    }

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        state->reenabled++;
        if (state->tap != NULL) {
            CGEventTapEnable(state->tap, true);
        }
        Log(LOG_W, @"[keyboard] system shortcut tap was disabled by %@, re-enabled (count=%llu)",
            type == kCGEventTapDisabledByTimeout ? @"timeout" : @"user input", state->reenabled);
        return event;
    }

    if ((type != kCGEventKeyDown && type != kCGEventKeyUp) || !MLShouldCaptureKeyEvent(event)) {
        return event;
    }

    // macOS acts on these before the app sees them; drop them here and queue the
    // same event in the app, where it takes the normal path to the host.
    NSEvent *appEvent = [NSEvent eventWithCGEvent:event];
    if (appEvent == nil) {
        return event;
    }
    [NSApp postEvent:appEvent atStart:NO];

    state->captured++;
    if (!state->loggedFirstCapture && type == kCGEventKeyDown) {
        state->loggedFirstCapture = YES;
        Log(LOG_I, @"[keyboard] first system shortcut captured keyCode=%lld flags=0x%llx",
            CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode), (unsigned long long)CGEventGetFlags(event));
    }
    return NULL;
}

@implementation MLSystemShortcutCapture {
    MLShortcutTapState *_state;
    CFRunLoopSourceRef _source;
}

- (BOOL)installed {
    return _state != NULL;
}

- (BOOL)installWithReason:(NSString *)reason {
    if (_state != NULL) {
        return YES;
    }
    if (![MLSystemGestureBlocker isAccessibilityTrusted]) {
        Log(LOG_I, @"[keyboard] system shortcut tap not installed reason=%@ accessibility=0", reason);
        return NO;
    }

    MLShortcutTapState *state = calloc(1, sizeof(MLShortcutTapState));
    if (state == NULL) {
        return NO;
    }
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap,
                                         kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault,
                                         CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp),
                                         MLSystemShortcutTapCallback,
                                         state);
    if (tap == NULL) {
        free(state);
        Log(LOG_W, @"[keyboard] system shortcut tap could not be created reason=%@", reason);
        return NO;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    if (source == NULL) {
        CFMachPortInvalidate(tap);
        CFRelease(tap);
        free(state);
        return NO;
    }
    state->tap = tap;
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    _state = state;
    _source = source;
    Log(LOG_I, @"[keyboard] system shortcut tap installed reason=%@", reason);
    return YES;
}

- (void)removeWithReason:(NSString *)reason {
    MLShortcutTapState *state = _state;
    if (state == NULL) {
        return;
    }
    _state = NULL;
    CGEventTapEnable(state->tap, false);
    if (_source != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source);
        _source = NULL;
    }
    CFMachPortInvalidate(state->tap);
    CFRelease(state->tap);
    Log(LOG_I, @"[keyboard] system shortcut tap removed reason=%@ captured=%llu reenabled=%llu",
        reason, state->captured, state->reenabled);
    free(state);
}

- (void)dealloc {
    [self removeWithReason:@"dealloc"];
}

@end
