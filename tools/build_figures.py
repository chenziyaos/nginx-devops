#!/usr/bin/env python3
"""Build the chapter figures from their specs.

Every figure is a spec, figures/<chapter>/NN.json, rendered to figures/<chapter>/NN.svg by
the lark-figure layout engine. The spec holds only content (a one-sentence title, nodes,
edges, tones); geometry and colors come from the engine, so all figures share one style.

  python3 tools/build_figures.py                 # every chapter
  python3 tools/build_figures.py ops-09 dev      # chapters whose id starts with an argument
  python3 tools/build_figures.py --png ops-09    # also keep PNG previews in figures/.preview/
  python3 tools/build_figures.py --check         # rebuild into a temp dir, fail if any
                                                 # committed SVG differs from its spec

The engine is not part of this repository: set LARK_FIGURE to its figure.py (default
~/.claude/skills/lark-figure/scripts/figure.py). The committed SVGs need nothing to view.
Exit code 1 if a spec fails the engine's checks or an SVG is stale; 2 if the engine is missing.
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
FIG = os.path.join(ROOT, 'figures')
ENGINE = os.environ.get('LARK_FIGURE',
                        os.path.expanduser('~/.claude/skills/lark-figure/scripts/figure.py'))

# The engine leaves the font to the viewer (the Feishu whiteboard). A browser showing the SVG
# through <img> falls back to its default font, often a serif one, so name a sans-serif stack.
FONTS = ('-apple-system, BlinkMacSystemFont, &quot;Segoe UI&quot;, &quot;PingFang SC&quot;, '
         '&quot;Hiragino Sans GB&quot;, &quot;Microsoft YaHei&quot;, &quot;Noto Sans CJK SC&quot;, '
         '&quot;Source Han Sans SC&quot;, Helvetica, Arial, sans-serif')
SVG_OPEN = '<svg xmlns="http://www.w3.org/2000/svg" '


def specs(prefixes):
    out = sorted(glob.glob(os.path.join(FIG, '*', '[0-9][0-9].json')))
    if prefixes:
        out = [p for p in out if any(os.path.basename(os.path.dirname(p)).startswith(x)
                                     for x in prefixes)]
    return out


def build(spec, tmp, png):
    """Render one spec into tmp; return (svg text, problems)."""
    cmd = [sys.executable, ENGINE, 'build', spec, '-o', tmp]
    if not png:
        cmd.append('--no-render')
    r = subprocess.run(cmd, capture_output=True, text=True)
    name = os.path.splitext(os.path.basename(spec))[0]
    try:
        report = json.loads(r.stdout)
    except ValueError:
        return None, [(r.stderr or r.stdout).strip().splitlines()[-1:] or ['engine failed']][0]
    problems = list(report.get('errors', []))
    problems += [f'{f.get("code")}: {f.get("msg", f.get("message", ""))}'
                 for f in report.get('lint', {}).get('findings', []) if f.get('level') == 'E']
    problems += [f'note: {n}' for n in report.get('notes', []) if 'ignored' in n]
    if r.returncode != 0 and not problems:
        problems.append(f'engine exit {r.returncode}: {r.stderr.strip()[-300:]}')
    path = os.path.join(tmp, name + '.svg')
    if not os.path.isfile(path):
        return None, problems or ['no SVG written']
    svg = open(path, encoding='utf-8').read()
    if not svg.startswith(SVG_OPEN):
        return None, problems + ['unexpected SVG header']
    svg = SVG_OPEN + f'font-family="{FONTS}" ' + svg[len(SVG_OPEN):]
    return svg, problems


def main(argv):
    check = '--check' in argv
    png = '--png' in argv
    prefixes = [a for a in argv if not a.startswith('--')]
    if not os.path.isfile(ENGINE):
        print(f'lark-figure engine not found at {ENGINE}; set LARK_FIGURE', file=sys.stderr)
        return 2
    todo = specs(prefixes)
    if not todo:
        print('no figure specs matched', file=sys.stderr)
        return 1
    bad = 0
    for spec in todo:
        rel = os.path.relpath(spec, ROOT)
        target = spec[:-5] + '.svg'
        with tempfile.TemporaryDirectory() as tmp:
            svg, problems = build(spec, tmp, png and not check)
            if png and not check and svg is not None:
                chapter = os.path.basename(os.path.dirname(spec))
                prev = os.path.join(FIG, '.preview', chapter)
                os.makedirs(prev, exist_ok=True)
                name = os.path.splitext(os.path.basename(spec))[0]
                if os.path.isfile(os.path.join(tmp, name + '.png')):
                    shutil.copy(os.path.join(tmp, name + '.png'), os.path.join(prev, name + '.png'))
        if svg is None or any(not p.startswith('note:') for p in problems):
            bad += 1
            print(f'FAIL  {rel}')
            for p in problems:
                print(f'      {p}')
            continue
        for p in problems:
            print(f'WARN  {rel}: {p}')
        if check:
            old = open(target, encoding='utf-8').read() if os.path.isfile(target) else None
            if old != svg:
                bad += 1
                print(f'STALE {os.path.relpath(target, ROOT)}: rebuild with tools/build_figures.py')
                continue
            print(f'OK    {rel}')
        else:
            with open(target, 'w', encoding='utf-8') as f:
                f.write(svg)
            print(f'BUILT {os.path.relpath(target, ROOT)}')
    print(f'{len(todo) - bad}/{len(todo)} figures ok')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
