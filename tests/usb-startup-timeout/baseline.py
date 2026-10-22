#!/usr/bin/env python3
"""Run the silent-pipe deadline assertion against an older production reader (expected failure)."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
ref = sys.argv[1] if len(sys.argv) > 1 else "259307d"
source = subprocess.check_output(["git", "show", f"{ref}:Limelight/Network/RemoteUSBForwardingSession.m"], cwd=root, text=True)
match = re.search(r"(?ms)^- \(NSData \*\)readLineFromHandle:.*?^}", source)
if not match:
    raise SystemExit("The selected revision does not contain the original blocking reader")
program = '''#import <Foundation/Foundation.h>
static const NSUInteger kMLRemoteUSBMaxLineBytes = 4096;
@interface Probe : NSObject
- (NSData *)readLineFromHandle:(NSFileHandle *)handle timeout:(NSTimeInterval)timeout;
@end
@implementation Probe
''' + match.group(0) + '''
@end
int main(void) { @autoreleasepool {
    NSPipe *pipe = [NSPipe pipe];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [[Probe new] readLineFromHandle:pipe.fileHandleForReading timeout:0.05];
        dispatch_semaphore_signal(done);
    });
    long blocked = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
    [pipe.fileHandleForWriting closeFile];
    if (blocked) dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    if (blocked) fprintf(stderr, "FAIL: original reader still blocked at 5x its configured deadline\\n");
    return blocked ? 1 : 0;
} }
'''
with tempfile.TemporaryDirectory(prefix="moonlight-usb-baseline-") as temp:
    path = Path(temp) / "baseline.m"
    path.write_text(program)
    binary = str(Path(temp) / "baseline")
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", str(path), "-o", binary], check=True)
    raise SystemExit(subprocess.run([binary], timeout=3).returncode)
