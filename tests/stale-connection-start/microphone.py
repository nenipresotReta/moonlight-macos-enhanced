#!/usr/bin/env python3
"""The production microphone-start/termination queue hops with no audio access."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--source-ref')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
path = 'Limelight/Stream/Connection.m'
source = subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=root, text=True) if args.source_ref else (root/path).read_text()

def method(marker):
    start=source.index(marker); i=source.index('{',start)+1; depth=1
    while depth:
        depth += (source[i]=='{')-(source[i]=='}'); i+=1
    return source[start:i]

methods=method('- (void)startMicrophoneIfNeeded')+'\n'+method('void ClConnectionTerminated(int errorCode)')
methods += '\n'+(method('- (BOOL)hasTerminated') if '- (BOOL)hasTerminated' in source else '- (BOOL)hasTerminated { return _hasTerminated != 0; }')
fixture=Path(__file__).with_name('microphone-fixture.m').read_text().replace('// PRODUCTION_METHODS',methods)
with tempfile.TemporaryDirectory(prefix='moonlight-stale-mic-') as temp:
    src=Path(temp)/'fixture.m'; exe=Path(temp)/'fixture'; src.write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Werror','-framework','Foundation',*shlex.split(os.environ.get('EXTRA_CFLAGS','')),str(src),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
