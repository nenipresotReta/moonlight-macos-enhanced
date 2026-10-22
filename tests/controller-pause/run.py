#!/usr/bin/env python3
"""Run production controller pause methods against isolated input sinks."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--backend', choices=['gc', 'hid'])
parser.add_argument('--source-ref', help='Read production sources from this Git revision')
args = parser.parse_args()

def source(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()

def extract(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

controller = source('Limelight/Input/ControllerSupport.m')
hid = source('Limelight/Input/HIDSupport.m')
header = source('Limelight/Input/HIDSupport_Internal.h')
setter = extract(controller, '- (void)setShouldSendInputEvents:')
getter = extract(controller, '- (BOOL)shouldSendInputEvents') if '- (BOOL)shouldSendInputEvents' in controller else ''
helper = extract(controller, '- (void)updateMouseModeButtons:') if '- (void)updateMouseModeButtons:' in controller else ''
callback = controller[controller.index('                [self evaluateControllerShortcuts:limeController];', controller.index('-(void) registerControllerCallbacks:')):]
callback = callback[:callback.index('                BOOL suppress =')]
mode = extract(controller, '- (void)setGamepadMouseModeActive:')
finished = extract(controller, '-(void) updateFinished:')
# The fixture models an already-announced controller. Host capability negotiation
# is not under test; retain every gate/state/shortcut/send statement after it.
arrival = extract(finished, '        if (!controller.controllerAnnounced)')
finished = finished.replace(arrival, 'assert(controller.controllerAnnounced);')
gc_methods = '\n'.join([getter, setter, helper, mode, finished])
hid_methods = '\n'.join(extract(hid, marker) for marker in [
    '- (BOOL)shouldSendInputEvents', '- (void)setShouldSendInputEvents:', '- (void)setInputContext:',
    '- (void)updateButtonFlags:', '- (void)setGamepadMouseModeActive:',
] + ([ '- (void)releaseControllerMouseButtons', '- (void)updateControllerMouseButtonsWithRouting:' ]
     if '- (void)releaseControllerMouseButtons' in hid else []))
pointer = source('Limelight/Input/HIDSupport+Pointer.m')
release = extract(pointer, '- (void)releaseAllPressedMouseButtons')
dispatch = extract(header, 'static inline void HIDDispatchMouseButtonInput') if 'static inline void HIDDispatchMouseButtonInput' in header else ''

with tempfile.TemporaryDirectory(prefix='moonlight-controller-pause-') as directory:
    tmp = Path(directory)
    for kind, replacements in [('gc', {'METHODS': gc_methods, 'CALLBACK': callback}),
                                ('hid', {'METHODS': hid_methods, 'DISPATCH': dispatch, 'RELEASE': release})]:
        if args.backend and kind != args.backend:
            continue
        text = (ROOT / 'tests/controller-pause' / f'{kind}.m').read_text()
        for key, value in replacements.items():
            text = text.replace(f'/* {key} */', value)
        file = tmp / f'{kind}.m'
        file.write_text(text)
        binary = tmp / kind
        subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-Werror',
                        '-Wno-unused-variable', '-Wno-unused-function',
                        '-I', str(ROOT / 'Limelight/Input'), '-framework', 'Foundation',
                        *shlex.split(os.environ.get('EXTRA_CFLAGS', '')),
                        str(file), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=20)
