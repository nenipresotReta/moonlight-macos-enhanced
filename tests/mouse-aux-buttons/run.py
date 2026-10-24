#!/usr/bin/env python3
"""Compile and execute actual GCMouse registration/cleanup methods with fake devices."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-ref', help='Read production source from this Git revision')
parser.add_argument('--source-root', type=Path, help='Read production source from another checkout')
parser.add_argument('--require-ownership', action='store_true', help='Require and test the shared-device ownership guard')
parser.add_argument('--release-regressions', action='store_true', help='Also test held buttons, queue ordering and capture/context transitions')
args = parser.parse_args()
root = args.source_root or Path(__file__).resolve().parents[2]
source_path = 'Limelight/Input/HIDSupport+Pointer.m'
source = (subprocess.check_output(['git', 'show', f'{args.source_ref}:{source_path}'], cwd=root, text=True)
          if args.source_ref else (root / source_path).read_text())


def method(signature, text=None):
    text = source if text is None else text
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        if text[end] == '{':
            depth += 1
        elif text[end] == '}':
            depth -= 1
        end += 1
    return text[start:end]


has_owners = 'static NSMapTable<GCMouse *, HIDSupport *> *HIDGCMouseCallbackOwners' in source
if args.require_ownership and not has_owners:
    parser.error('The requested source does not have shared-device ownership guards')
owner_helper = method('static NSMapTable<GCMouse *, HIDSupport *> *HIDGCMouseCallbackOwners') if has_owners else ''
def read(path):
    return (subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=root, text=True)
            if args.source_ref else (root / path).read_text())
header = read('Limelight/Input/HIDSupport_Internal.h')
base = read('Limelight/Input/HIDSupport.m')
state = ''
if '@interface HIDGCMouseButtonState' in source:
    state = source[source.index('@interface HIDGCMouseButtonState'):source.index('// GCMouse instances')]
helpers = '\n'.join(method(marker, header) for marker in [
    'static inline uint32_t HIDMouseButtonBitForButton',
    'static inline void HIDDispatchInput', 'static inline void HIDDispatchMouseButtonInput'] if marker in header)
methods = '\n'.join(method(marker) for marker in [
    '- (uint32_t)gcMousePressedButtons', '- (uint32_t)clearGCMousePressedButtons',
    '- (void)handleGCMouseButton:', '- (void)releaseGCMouseButtonsForMouse:',
    '- (BOOL)hasPressedMouseButtons', '- (void)releaseAllPressedMouseButtons',
] if marker in source)
methods += '\n' + '\n'.join(method(marker, base) for marker in [
    '- (BOOL)shouldSendInputEvents', '- (void)setShouldSendInputEvents:', '- (void)setInputContext:'])
fixture = (Path(__file__).parent / 'fixture.m').read_text()
implementation = (state + owner_helper + helpers + '\n@implementation HIDSupport\n'
                  '@synthesize shouldSendInputEvents = _shouldSendInputEvents;\n'
                  '@synthesize inputContext = _inputContext;\n'
                  '- (void)handleGCMouseScrollValueY:(float)value { self.scrollValue += value; }\n'
                  '- (void)releaseControllerMouseButtons {}\n'
                  '- (void)releaseAllModifierKeys {}\n'
                  '- (void)sendControllerEvent {}\n'
                  '- (void)rumbleLowFreqMotor:(int)l highFreqMotor:(int)h {}\n'
                  '- (void)syncScrollTraceDiagnosticsPreferenceToInputContext {}\n'
                  '- (uint64_t)evaluateControllerShortcuts { return 0; }\n'
                  '- (void)updateControllerMouseButtonsWithRouting:(uint64_t)r {}\n'
                  '- (void)recordMouseButtonDiagnosticsAction:(NSString *)a button:(int)b mask:(uint32_t)m synthetic:(BOOL)s {}\n'
                  + methods + '\n' + method('-(void)registerMouseCallbacks:') + '\n'
                  + method('-(void)unregisterMouseCallbacks:') + '\n@end\n')
fixture = fixture.replace('/* MENU GESTURE */', read('Limelight/Input/ControllerMenuGesture.h').replace('#pragma once', ''))
fixture = fixture.replace('/* PRODUCTION_METHODS */', implementation)
fixture = f'#define RELEASE_REGRESSIONS {int(args.release_regressions)}\n' + fixture
with tempfile.TemporaryDirectory(prefix='moonlight-mouse-aux-buttons-') as tmp:
    path = Path(tmp)
    (path / 'test.m').write_text(f'#define HAS_OWNERS {int(has_owners)}\n' + fixture)
    subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-Werror', '-framework', 'Foundation',
                    *shlex.split(os.environ.get('EXTRA_CFLAGS', '')),
                    str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True, timeout=30)
