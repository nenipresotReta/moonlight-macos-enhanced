"""Exercise production mouse button dispatch and pause with a controlled input queue."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-ref', help='Read production code from a Git ref for fail-before checks')
args = parser.parse_args()


def source(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def definition(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


internal = source('Limelight/Input/HIDSupport_Internal.h')
pointer = source('Limelight/Input/HIDSupport+Pointer.m')
base = source('Limelight/Input/HIDSupport.m')
helpers = '\n'.join(definition(internal, signature) for signature in [
    'static inline PML_INPUT_STREAM_CONTEXT HIDInputContext',
    'static inline bool HIDValidateInputContext',
    'static inline void HIDDispatchInput',
    'static inline uint32_t HIDMouseButtonBitForButton',
    'static inline CGFloat HIDAbsoluteMouseReferencePrecisionScale',
    'static inline BOOL HIDAbsoluteMousePositionForViewPoint',
    'static inline BOOL HIDShouldUseHybridFreeMouseMotion',
    'static inline BOOL HIDShouldUseCoreHIDFreeMouseAbsoluteSync',
])
if 'static inline void HIDDispatchMouseButtonInput' in internal:
    helpers += '\n' + definition(internal, 'static inline void HIDDispatchMouseButtonInput')
if '@interface HIDAbsolutePointerBatch' in pointer:
    helpers += '\n' + pointer[pointer.index('@interface HIDAbsolutePointerBatch'):pointer.index('@implementation HIDSupport (Pointer)')]
methods = '\n'.join(definition(pointer, signature) for signature in [
    '- (BOOL)hasPressedMouseButtons', '- (void)releaseAllPressedMouseButtons',
    '- (void)mouseDown:', '- (void)mouseUp:', '- (void)sendMouseButton:',
])
methods += '\n' + '\n'.join(definition(base, signature) for signature in [
    '- (BOOL)shouldSendInputEvents', '- (void)setShouldSendInputEvents:', '- (void)setInputContext:',
    '- (void)recordAbsoluteInputDiagnosticsFrom:',
])
properties = '\n'.join(line for line in internal.splitlines() if line.startswith('@property') and any(
    key in line for key in ['inputQueue', 'pressedMouseButtonsMask', 'mouseButtonInputGeneration',
                          'mouseButtonContextGeneration', 'useGCMouse', 'useCoreHIDMouse',
                          'coreHIDMouseRuntimeFailed', 'AbsolutePointer', 'inputDiagnostics',
                          'freeMouseVirtualCursor']))
fixture = Path(__file__).with_name('fixture.m').read_text()
program = fixture.replace('/* PROPERTIES */', properties).replace('/* HELPERS */', helpers).replace('/* METHODS */', methods)
program = program.replace('/* MENU GESTURE */', source('Limelight/Input/ControllerMenuGesture.h').replace('#pragma once', ''))
with tempfile.TemporaryDirectory(prefix='moonlight-button-release-') as tmp:
    test = Path(tmp) / 'test.m'
    test.write_text(program)
    flags = ['clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
             '-Wno-unused-parameter', '-Wno-unused-function', '-framework', 'AppKit']
    if os.environ.get('SANITIZE'):
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    binary = Path(tmp) / 'test'
    subprocess.run(flags + [str(test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
