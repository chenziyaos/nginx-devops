#!/usr/bin/env python3
"""Find the nginx versions whose change log mentions a directive, variable or phrase.

Usage:
  python3 tools/since.py limit_req_dry_run          # versions mentioning "limit_req_dry_run"
  python3 tools/since.py '"delay" parameter'        # any phrase, case-insensitive
  python3 tools/since.py -a 'keepalive'             # print every matching entry, not only the oldest five
  python3 tools/since.py --stats 2024-11-01         # count the entries of each type since a date

Reads docs/xml/nginx/changes.xml of the pinned source (release-1.31.10) and prints the
English text of each matching change with its version, date and type, oldest first.
Use it before writing "available since 1.x.y": the oldest "feature" entry is usually
the answer, later entries are changes and bug fixes. With --stats it counts the entries
of each type released on or after a date, per branch, and sorts the security entries into
memory errors (overflow, overread, use-after-free, uninitialized memory, crash) and the rest.
"""
import html
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XML = os.path.join(ROOT, '.nginx-src', 'release-1.31.10', 'docs', 'xml', 'nginx', 'changes.xml')


def entries():
    text = open(XML, encoding='utf-8').read()
    for m in re.finditer(r'<changes ver="([\d.]+)" date="([\d-]+)"\s*>(.*?)</changes>', text, re.S):
        ver, date, body = m.groups()
        for c in re.finditer(r'<change(?: type="(\w+)")?>(.*?)</change>', body, re.S):
            en = re.search(r'<para lang="en">(.*?)</para>', c.group(2), re.S)
            if en:
                para = html.unescape(re.sub(r'<[^>]+>', '', en.group(1)))
                yield ver, date, c.group(1) or 'change', ' '.join(para.split())


MEMORY = re.compile(r'overflow|overread|use-after-free|uninitialized|segmentation fault|'
                    r'memory corruption|memory disclosure|crash', re.I)


def stats(since):
    hits = [e for e in entries() if e[1] >= since]
    if not hits:
        print(f'no release on or after {since}')
        return 1
    vers = {e[0] for e in hits}
    key = lambda v: tuple(map(int, v.split('.')))
    print(f'{len(vers)} releases, {min(vers, key=key)} to {max(vers, key=key)}')
    kinds = sorted({e[2] for e in hits})
    branches = sorted({'.'.join(e[0].split('.')[:2]) for e in hits}, key=key)
    print('branch  releases  ' + '  '.join(f'{k:>10}' for k in kinds))
    for b in branches + ['all']:
        sel = [e for e in hits if b == 'all' or e[0].startswith(b + '.')]
        print(f'{b:<7} {len({e[0] for e in sel}):>8}  '
              + '  '.join(f'{sum(e[2] == k for e in sel):>10}' for k in kinds))
    sec = [e for e in hits if e[2] == 'security']
    mem = [e for e in sec if MEMORY.search(e[3])]
    print(f'security: {len(sec)}, memory errors: {len(mem)}, other: {len(sec) - len(mem)}')
    years = sorted({e[1][:4] for e in hits})
    print('security by year: ' + ', '.join(f'{y} {sum(e[1][:4] == y for e in sec)}' for y in years))
    return 0


def main():
    args = sys.argv[1:]
    if args[:1] == ['--stats'] and len(args) == 2:
        return stats(args[1])
    show_all = '-a' in args
    args = [a for a in args if a != '-a']
    if not args:
        sys.exit(__doc__)
    needle = ' '.join(args).lower()
    hits = [e for e in entries() if needle in e[3].lower()]
    hits.reverse()
    if not hits:
        print(f'no change log entry mentions {needle!r}; do not write a version for it')
        return 1
    for ver, date, kind, para in (hits if show_all else hits[:5]):
        print(f'{ver} ({date}) {kind}: {para}')
    if not show_all and len(hits) > 5:
        print(f'... {len(hits) - 5} more, use -a')
    return 0


if __name__ == '__main__':
    sys.exit(main())
