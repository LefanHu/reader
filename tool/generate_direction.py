#!/usr/bin/env python3
"""Generate first-strong ranges from Unicode 17.0.0 DerivedBidiClass.txt.

Download https://www.unicode.org/Public/17.0.0/ucd/extracted/DerivedBidiClass.txt
and pass its local path, then run dart format lib/text/direction.dart. Explicit
properties override @missing defaults; neutral classes never choose direction.
"""
import argparse
import pathlib
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('data', type=pathlib.Path)
args = parser.parse_args()
data = args.data.read_text()
if not data.startswith('# DerivedBidiClass-17.0.0.txt'):
    raise SystemExit('Expected Unicode 17.0.0 DerivedBidiClass.txt')
properties = bytearray(0x110000)
kinds = {'L': 1, 'Left_To_Right': 1, 'R': 2, 'Right_To_Left': 2,
         'AL': 2, 'Arabic_Letter': 2}


def apply(start, end, name):
    start = int(start, 16)
    end = int(end or f'{start:X}', 16)
    properties[start:end + 1] = bytes([kinds.get(name, 0)]) * (end - start + 1)


for line in data.splitlines():
    match = re.search(r'@missing:\s*([0-9A-F]+)(?:\.\.([0-9A-F]+))?;\s*(\w+)', line)
    if match:
        apply(*match.groups())
for line in data.splitlines():
    match = re.match(r'([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*(\w+)', line)
    if match:
        apply(*match.groups())

ranges = []
start = end = 0
kind = properties[0]
for rune, next_kind in enumerate(properties):
    if next_kind == kind:
        end = rune
    else:
        if kind:
            ranges.append((start, end, kind))
        start = end = rune
        kind = next_kind
if kind:
    ranges.append((start, end, kind))
path = pathlib.Path(__file__).resolve().parent.parent / 'lib/text/direction.dart'
source = path.read_text()
prefix = source[:source.index('const _strong = <int>[')]
prefix = prefix.replace('Unicode 15.1.0', 'Unicode 17.0.0')
path.write_text(prefix + 'const _strong = <int>[\n' + ''.join(
    f'  0x{start:x}, 0x{end:x}, {kind},\n' for start, end, kind in ranges
) + '];\n')
