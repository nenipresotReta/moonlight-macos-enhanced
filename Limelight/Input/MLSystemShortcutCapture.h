//
//  MLSystemShortcutCapture.h
//  Moonlight for macOS
//
//  Keeps macOS from acting on its own keyboard shortcuts (⌘Tab, ⌘`, ⌘Space,
//  ⌃Space, ⌃arrows, screenshots, function keys) while the stream has the
//  keyboard, and hands those key events to the app so they reach the host.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MLSystemShortcutCapture : NSObject

/// YES while the event tap is installed.
@property (nonatomic, readonly) BOOL installed;

/// Installs the tap on the main run loop. Returns NO (and logs) when Accessibility
/// permission is missing or the tap cannot be created.
- (BOOL)installWithReason:(NSString *)reason;

/// Removes the tap immediately. Safe to call when nothing is installed.
- (void)removeWithReason:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
