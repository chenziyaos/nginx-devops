#!/usr/bin/env python3
"""Print a source excerpt as a fenced block that tools/check_docs.py accepts.

Usage:
  python3 tools/excerpt.py src/http/ngx_http_core_module.c 1446-1470
  python3 tools/excerpt.py src/http/ngx_http_core_module.c ngx_http_core_find_location
  python3 tools/excerpt.py modules/ngx_http_hello_module/ngx_http_hello_module.c 10-30

A line range prints exactly those lines. A function name prints the function from its
return-type line to the closing brace and reports the range on stderr, so you can narrow it.
Paths under src/ are read from the pinned source (.nginx-src/release-1.31.9).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, '.nginx-src', 'release-1.31.9')


def find_function(lines, name):
    for i, line in enumerate(lines):
        if re.match(r'^' + re.escape(name) + r'\(', line):
            start = i - 1 if i > 0 and lines[i - 1].strip() and not lines[i - 1].startswith(' ') else i
            for j in range(i, len(lines)):
                if lines[j] == '}':
                    return start + 1, j + 1
    sys.exit(f'function {name} not found (the name must start a line, as in nginx style)')


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rel, spec = sys.argv[1], sys.argv[2]
    path = os.path.join(SRC if rel.startswith('src/') else ROOT, rel)
    lines = open(path, encoding='utf-8').read().split('\n')
    m = re.fullmatch(r'(\d+)-(\d+)', spec)
    if m:
        a, b = int(m.group(1)), int(m.group(2))
    else:
        a, b = find_function(lines, spec)
        print(f'{rel}:{a}-{b}', file=sys.stderr)
    if not (1 <= a <= b <= len(lines)):
        sys.exit(f'range {a}-{b} outside 1-{len(lines)}')
    print('```c')
    print(f'// {rel}:{a}-{b}')
    print('\n'.join(lines[a - 1:b]))
    print('```')
    return 0


if __name__ == '__main__':
    sys.exit(main())
