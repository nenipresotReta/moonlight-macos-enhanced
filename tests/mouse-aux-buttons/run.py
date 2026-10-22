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
args = parser.parse_args()
root = args.source_root or Path(__file__).resolve().parents[2]
source_path = 'Limelight/Input/HIDSupport+Pointer.m'
source = (subprocess.check_output(['git', 'show', f'{args.source_ref}:{source_path}'], cwd=root, text=True)
          if args.source_ref else (root / source_path).read_text())


def method(signature):
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


has_owners = 'static NSMapTable<GCMouse *, HIDSupport *> *HIDGCMouseCallbackOwners' in source
if args.require_ownership and not has_owners:
    parser.error('The requested source does not have shared-device ownership guards')
owner_helper = method('static NSMapTable<GCMouse *, HIDSupport *> *HIDGCMouseCallbackOwners') if has_owners else ''
fixture = (Path(__file__).parent / 'fixture.m').read_text()
implementation = (owner_helper + '\n@implementation HIDSupport\n'
                  '- (void)handleGCMouseScrollValueY:(float)value { self.scrollValue += value; }\n'
                  + method('-(void)registerMouseCallbacks:') + '\n'
                  + method('-(void)unregisterMouseCallbacks:') + '\n@end\n')
fixture = fixture.replace('/* PRODUCTION_METHODS */', implementation)
with tempfile.TemporaryDirectory(prefix='moonlight-mouse-aux-buttons-') as tmp:
    path = Path(tmp)
    (path / 'test.m').write_text(f'#define HAS_OWNERS {int(has_owners)}\n' + fixture)
    subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    *shlex.split(os.environ.get('EXTRA_CFLAGS', '')),
                    str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
