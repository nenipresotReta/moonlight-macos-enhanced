"""Run extracted production pointer code against an isolated packet sink on macOS."""
from pathlib import Path
import os
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-ref', help='Read production code from a Git ref (for fail-before checks)')
parser.add_argument('--case', choices=['motion', 'queue', 'isolation', 'concurrent'])
options = parser.parse_args()


def source(path):
    if options.source_ref:
        return subprocess.check_output(['git', 'show', f'{options.source_ref}:{path}'], cwd=root, text=True)
    return (root / path).read_text()


def definition(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


pointer = source('Limelight/Input/HIDSupport+Pointer.m')
internal = source('Limelight/Input/HIDSupport_Internal.h')
base = source('Limelight/Input/HIDSupport.m')
helpers = pointer[pointer.index('static inline CGFloat HIDClampFreeMouseCoordinate'):
                  pointer.index('@implementation HIDSupport (Pointer)')]
helpers += '\n' + '\n'.join(definition(internal, name) for name in [
    'static inline CGFloat HIDAbsoluteMouseReferencePrecisionScale',
    'static inline BOOL HIDAbsoluteMousePositionForViewPoint',
    'static inline BOOL HIDShouldUseHybridFreeMouseMotion',
    'static inline BOOL HIDShouldUseCoreHIDFreeMouseAbsoluteSync',
    'static inline BOOL HIDShouldUseAbsolutePointerPath',
    'static inline uint32_t HIDMouseButtonBitForButton',
])
legacy = '- (BOOL)seedFreeMouseVirtualCursorWithViewPoint:' not in pointer
names = [
    '- (void)setFreeMouseVirtualCursorActive:',
    '- (void)resetFreeMouseVirtualCursorState',
    '- (void)updateFreeMouseVirtualCursorAnchorWithViewPoint:',
    '- (BOOL)seedFreeMouseVirtualCursorWithViewPoint:',
    '- (BOOL)sendCurrentFreeMouseVirtualCursorPosition',
    '- (BOOL)getFreeMouseVirtualCursorPoint:',
    '- (void)dispatchAbsolutePointerBatch:',
    '- (void)enqueueAbsolutePointerHostX:',
    '- (void)sendCoalescedAbsoluteMousePositionForViewPoint:',
    '- (BOOL)dispatchVirtualFreeMouseDeltaX:',
    '- (void)sendAbsoluteMousePositionForViewPoint:',
    '- (void)sendMouseButton:',
    '- (void)mouseDown:',
    '- (void)mouseUp:',
    '- (void)mouseMoved:',
]
if legacy:
    names = [name for name in names if not any(key in name for key in [
        'seedFreeMouseVirtualCursor', 'sendCurrentFreeMouse', 'dispatchAbsolutePointerBatch', 'enqueueAbsolutePointerHostX'])]
    names += ['- (BOOL)reconcileFreeMouseVirtualCursorToViewPoint:', '- (void)dispatchPendingCoalescedAbsolutePointerPosition']
methods = '\n'.join(definition(pointer, name) for name in names)
if legacy:
    # Adapt the renamed API only; execute the original reconciliation and queue.
    methods += '''
- (BOOL)seedFreeMouseVirtualCursorWithViewPoint:(NSPoint)p referenceSize:(NSSize)s {
    return [self reconcileFreeMouseVirtualCursorToViewPoint:p referenceSize:s correctionThreshold:1.5];
}
- (BOOL)sendCurrentFreeMouseVirtualCursorPosition { return NO; }
'''
methods += '\n' + definition(base, '- (void)recordAbsoluteInputDiagnosticsFrom:')
# Compile the actual property declarations; a misspelled fixture property must fail.
properties = '\n'.join(line for line in internal.splitlines() if line.startswith('@property') and any(
    name in line for name in [
        'freeMouseVirtualCursor', 'AbsolutePointer', 'inputDiagnostics', 'inputQueue',
        'precisionTouchpad', 'pressedMouseButtonsMask', 'useGCMouse', 'useCoreHIDMouse',
        'coreHIDMouseRuntimeFailed',
    ]))
fixture = (Path(__file__).parent / 'fixture.m').read_text()
program = fixture.replace('/* PROPERTIES */', properties).replace('/* HELPERS */', helpers).replace('/* METHODS */', methods)
with tempfile.TemporaryDirectory(prefix='moonlight-free-mouse-') as tmp:
    path = Path(tmp)
    (path / 'test.m').write_text(program)
    args = ['clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
            '-Wno-unused-parameter', '-Wno-unused-function', '-framework', 'AppKit']
    if os.environ.get('SANITIZE'):
        args += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    subprocess.run(args + [str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True, env={**os.environ, 'POINTER_TEST_CASE': options.case or ''})
