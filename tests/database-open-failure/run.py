#!/usr/bin/env python3
"""Run production Objective-C methods against temporary Core Data stores only."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source-ref', help='Compile production sources from a Git ref (for fail-before checks)')
args = parser.parse_args()

def read(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()

def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def strip_imports(source):
    return re.sub(r'^#import .*$', '', source, flags=re.M)

singleton = strip_imports(read('Limelight/DatabaseSingleton.h')) + '\n' + strip_imports(read('Limelight/DatabaseSingleton.m'))
data = read('Limelight/Database/DataManager.m')
data_methods = []
for signature in ['- (id) init', '- (NSManagedObjectContext *)databaseContext', '- (BOOL)isAvailable',
                  '- (void) updateUniqueId:', '- (NSString*) getUniqueId', '- (Settings*) retrieveSettings',
                  '- (void) saveData', '- (TemporarySettings*) getSettings', '- (NSArray*) getHosts', '- (NSArray*) fetchRecords:']:
    if signature in data:
        data_methods.append(method(data, signature))
identity = method(read('Limelight/Crypto/IdManager.m'), '+ (NSString*) getUniqueId')
program = (ROOT / 'tests/database-open-failure/fixture.m').read_text()
program = program.replace('/* PRODUCTION_SINGLETON */', singleton)
program = program.replace('/* PRODUCTION_DATA_MANAGER */', '\n\n'.join(data_methods).replace('DatabaseSingleton', 'FixtureDatabase'))
program = program.replace('/* PRODUCTION_IDENTITY */', identity.replace('[IdManager generateUniqueId]', '[IdentityGenerator generateUniqueId]'))
with tempfile.TemporaryDirectory(prefix='moonlight-database-regression-') as directory:
    path = Path(directory)
    (path / 'fixture.m').write_text(program)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
                    '-Wno-unused-parameter', '-framework', 'Foundation', '-framework', 'CoreData',
                    str(path / 'fixture.m'), '-o', str(path / 'fixture')], check=True)
    subprocess.run([str(path / 'fixture'), '-com.apple.CoreData.ConcurrencyDebug', '1'], check=True, timeout=45,
                   env={**os.environ, 'MOONLIGHT_DATABASE_TEST_DIR': directory})
