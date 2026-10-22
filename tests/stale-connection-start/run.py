#!/usr/bin/env python3
"""Compile complete production startup callbacks against deterministic fake queues."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--source-ref', help='read production methods from this Git revision')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]

def read(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=root, text=True)
    return (root / path).read_text()

def method(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    i = opening + 1
    while depth:
        depth += (source[i] == '{') - (source[i] == '}')
        i += 1
    return source[start:i]

source = read('Limelight/macOS/ViewControllers/StreamViewController.m')
proxy_source, owner_source = source.split('#pragma mark - ConnectionCallbacks', 1)
fixed = '- (void)connectionStartedForGeneration:' in owner_source
owner_markers = ['- (void)connectionStarted {',
                 '- (void)stageComplete:(const char *)stageName {',
                 '- (void)handleFirstFramePresentedForGeneration:',
                 '- (void)scheduleInitialRenderedFrameCheckForGeneration:']
if fixed:
    owner_markers += ['- (BOOL)isCurrentStartupConnection:',
                      '- (void)retryInputBindingForConnection:',
                      '- (void)connectionStartedForGeneration:',
                      '- (void)stageComplete:(const char *)stageName forGeneration:']
owner_methods = '\n\n'.join(method(owner_source, m) for m in owner_markers)
proxy_methods = '\n\n'.join(method(proxy_source, m) for m in [
    '- (BOOL)forwardIfCurrentNamed:', '- (void)connectionStarted {',
    '- (void)stageComplete:(const char *)stageName {'])
fixture = Path(__file__).with_name('fixture.m').read_text()
fixture = fixture.replace('// OWNER_METHODS', owner_methods).replace('// PROXY_METHODS', proxy_methods)
fixture = f'#define SCOPED_START {int(fixed)}\n' + fixture
with tempfile.TemporaryDirectory(prefix='moonlight-stale-start-') as temp:
    src = Path(temp) / 'fixture.m'
    exe = Path(temp) / 'fixture'
    src.write_text(fixture)
    command = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror',
               '-Wno-objc-method-access', '-Wno-unused-variable',
               '-framework', 'Foundation', '-framework', 'AppKit',
               *shlex.split(os.environ.get('EXTRA_CFLAGS', '')), str(src), '-o', str(exe)]
    subprocess.run(command, check=True)
    subprocess.run([str(exe)], check=True)

subprocess.run([sys.executable, str(Path(__file__).with_name("microphone.py")), *sys.argv[1:]], check=True)
