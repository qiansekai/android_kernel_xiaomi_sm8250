#!/usr/bin/env python3
"""Replace compiler identity strings in kernel Image with stock MIUI values."""
import sys
import os

IMAGE_PATH = sys.argv[1] if len(sys.argv) > 1 else 'out/arch/arm64/boot/Image'

if not os.path.exists(IMAGE_PATH):
    print(f'Image not found: {IMAGE_PATH}')
    sys.exit(1)

with open(IMAGE_PATH, 'rb') as f:
    data = bytearray(f.read())

# Pairs: (current_substring, replacement)
# Replacement will be NUL-padded to match original length
replacements = [
    (b'ZyC clang version 15.0.7', b'clang 10.0.7'),
    (b'LLD 15.0.7', b'LLD 10.0.1'),
    (b'ZyC clang', b'clang'),
]

patched = 0
for old, new in replacements:
    idx = data.find(old)
    if idx >= 0:
        padded = new + b'\x00' * (len(old) - len(new))
        data[idx:idx+len(old)] = padded
        print(f'  Patched "{old.decode()}" -> "{new.decode()}" at offset {idx}')
        patched += 1
    else:
        print(f'  WARNING: "{old.decode()}" not found in Image')

if patched > 0:
    with open(IMAGE_PATH, 'wb') as f:
        f.write(data)
    print(f'Banner patched ({patched} replacements)')
else:
    print('No patterns found, skipping')
