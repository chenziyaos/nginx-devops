#!/usr/bin/env python3
"""Find the nginx versions whose change log mentions a directive, variable or phrase.

Usage:
  python3 tools/since.py limit_req_dry_run          # versions mentioning "limit_req_dry_run"
  python3 tools/since.py '"delay" parameter'        # any phrase, case-insensitive
  python3 tools/since.py -a 'keepalive'             # print every matching entry, not only the oldest five

Reads docs/xml/nginx/changes.xml of the pinned source (release-1.31.10) and prints the
English text of each matching change with its version, date and type, oldest first.
Use it before writing "available since 1.x.y": the oldest "feature" entry is usually
the answer, later entries are changes and bug fixes.
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


def main():
    args = sys.argv[1:]
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
