#!/usr/bin/env python3
"""Check that every chapter quotes nginx source, configs and lab output faithfully.

Usage:
  python3 tools/check_docs.py                 # all chapters under ops/ and dev/
  python3 tools/check_docs.py ops/05-*.md     # some chapters

Rules (each fenced block must declare where it comes from on its first line):

  ```c      // src/core/ngx_palloc.c:19-44      nginx source, lines 19..44 of release-1.31.10.
                                                 Body lines must appear in that range, in order, with the same indentation;
                                                 "/* ... */" lines mark elisions.
            // modules/<dir>/<file>.c:10-30      the repo's own module source, same rule.
            // labs/<id>/<file>.c:10-30          a lab's own C program, same rule.
            // 示意                              pseudo code, not checked.
  ```nginx  # lab: labs/ops-05/conf/nginx.conf   lines must appear in that file, in order;
                                                 "# ..." lines mark elisions.
            # context: main|http|server|location|stream|upstream
                                                 wrapped into a minimal config and run through nginx -t.
            # 示意                               not checked (counted in the summary).
  ```text   # labs/ops-05 ## <step title>       lines must appear, in order, in that step's
                                                 section of labs/ops-05/expected.txt; "..." elides.

Links to https://github.com/nginx/nginx/blob/<ref>/<path>#Ln[-Lm] must use the pinned ref,
point at an existing line, and when the link text is a `code` identifier, that identifier
must occur within lines n..max(m, n+2). Relative links must point at existing files. A figure is an image link
![<title>](../figures/<chapter>/NN.svg) whose text equals the title of its spec NN.json.
Chapters under ops/ and dev/ must also follow the skeleton in spec: 一句话结论, 导读,
5-9 numbered sections each with a **小结** line, 已知局限与待核实, 修订记录, at least one
3 figures, 4 quoted lab outputs, at most 2 示意 blocks, a minimum length,
lab configs kept as files, and expect checks in run.sh for at least half of its steps. Every x.y.z version in
the prose must exist in changes.xml; --versions lists each mention with its sentence so a
reviewer can check it against tools/since.py.
Exit code 1 on any error.
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = 'release-1.31.10'
SRC = os.path.join(ROOT, '.nginx-src', REF)
NGINX = os.path.join(ROOT, '.nginx', 'sbin', 'nginx')
GH = 'https://github.com/nginx/nginx/blob/'

FENCE = re.compile(r'^```(\w*)[^\n]*\n(.*?)^```\s*$', re.M | re.S)
LINK = re.compile(r'\[([^\]]*)\]\(([^)\s]+)\)')
FIGURE = re.compile(r'!\[([^\]]*)\]\((\.\./figures/[\w-]+/\d\d\.svg)\)')
SRC_HDR = re.compile(r'^//\s*((?:src|modules|labs)/[\w./-]+):(\d+)-(\d+)\s*$')
CONF_LAB = re.compile(r'^#\s*lab:\s*(labs/[\w./-]+)\s*$')
CONF_CTX = re.compile(r'^#\s*context:\s*(main|http|server|location|stream|upstream)\s*$')
TEXT_LAB = re.compile(r'^#\s*(labs/[\w-]+)\s+##\s*(.+?)\s*$')
SKETCH = re.compile(r'^(//|#)\s*示意')

WRAP = {
    'main': '{b}\nevents {{}}\n',
    'http': 'events {{}}\nhttp {{\n{b}\n}}\n',
    'server': 'events {{}}\nhttp {{\nserver {{\nlisten 127.0.0.1:1;\n{b}\n}}\n}}\n',
    'location': 'events {{}}\nhttp {{\nserver {{\nlisten 127.0.0.1:1;\nlocation / {{\n{b}\n}}\n}}\n}}\n',
    'stream': 'events {{}}\nstream {{\n{b}\n}}\n',
    'upstream': 'events {{}}\nhttp {{\nupstream u {{\n{b}\n}}\nserver {{\nlisten 127.0.0.1:1;\nlocation / {{ proxy_pass http://u; }}\n}}\n}}\n',
}

_files = {}


def lines_of(path):
    if path not in _files:
        with open(path, encoding='utf-8', errors='replace') as f:
            _files[path] = f.read().split('\n')
    return _files[path]


def norm(s):
    return ' '.join(s.split())


def subsequence(want, have):
    """Index of the first line of `want` that cannot be matched in order inside `have`, or None."""
    j = 0
    for i, w in enumerate(want):
        while j < len(have) and have[j] != w:
            j += 1
        if j == len(have):
            return i
        j += 1
    return None


def check_excerpt(body, hdr, elide):
    """Body lines (minus elisions/blank lines) must appear in order inside the cited lines."""
    path, a, b = hdr
    full = os.path.join(SRC if path.startswith('src/') else ROOT, path)
    if not os.path.isfile(full):
        return f'{path}: no such file'
    src = lines_of(full)
    a, b = int(a), int(b)
    if not (1 <= a <= b <= len(src)):
        return f'{path}:{a}-{b}: out of range (file has {len(src)} lines)'
    # exact lines (trailing spaces aside): excerpts keep nginx's own indentation
    want = [x.rstrip() for x in body if x.strip() and not elide(x)]
    have = [x.rstrip() for x in src[a - 1:b]]
    bad = subsequence(want, have)
    if bad is not None:
        return f'{path}:{a}-{b}: line not found in range: {want[bad]!r}'
    return None


def nginx_t(conf_text):
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, 'logs'))
        os.makedirs(os.path.join(tmp, 'conf'))
        with open(os.path.join(tmp, 'conf', 'nginx.conf'), 'w', encoding='utf-8') as f:
            f.write(conf_text)
        r = subprocess.run([NGINX, '-t', '-q', '-p', tmp + '/', '-c', 'conf/nginx.conf',
                            '-e', 'logs/error.log', '-g', 'pid logs/nginx.pid;'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            lines = r.stderr.strip().splitlines() or ['(no output)']
            msg = next((x for x in lines if '[emerg]' in x), lines[-1])
            return msg.replace(tmp + '/', '')
    return None


def step_section(lab, title):
    path = os.path.join(ROOT, lab, 'expected.txt')
    if not os.path.isfile(path):
        return None
    out, on = [], False
    for line in lines_of(path):
        if line.startswith('## '):
            if on:
                break
            on = line[3:].strip() == title
            continue
        if on:
            out.append(line)
    return out if on or out else None


def check_block(lang, body, errors, stats):
    first = body[0].strip() if body else ''
    rest = body[1:]
    if not lang:
        return 'fenced block without a language; use text, bash, c or nginx'
    if lang == 'mermaid':
        return 'mermaid block; draw it as figures/<id>/NN.json and build it with tools/build_figures.py'
    if lang == 'c':
        m = SRC_HDR.match(first)
        if m:
            err = check_excerpt(rest, m.groups(), lambda x: x.strip() == '/* ... */')
            stats['c'] += 1
            return err
        if SKETCH.match(first):
            stats['sketch'] += 1
            return None
        return 'c block without a "// src/<file>:<a>-<b>" or "// 示意" header'
    if lang == 'nginx':
        m = CONF_LAB.match(first)
        if m:
            path = os.path.join(ROOT, m.group(1))
            if not os.path.isfile(path):
                return f'{m.group(1)}: no such file'
            want = [norm(x) for x in rest if x.strip() and x.strip() != '# ...']
            have = [norm(x) for x in lines_of(path)]
            bad = subsequence(want, have)
            stats['conf'] += 1
            return None if bad is None else f'{m.group(1)}: line not found: {want[bad]!r}'
        m = CONF_CTX.match(first)
        if m:
            stats['conf'] += 1
            return nginx_t(WRAP[m.group(1)].format(b='\n'.join(rest)))
        if SKETCH.match(first):
            stats['sketch'] += 1
            return None
        return 'nginx block without "# lab: <file>", "# context: <ctx>" or "# 示意" header'
    if lang == 'text':
        m = TEXT_LAB.match(first)
        if not m:
            return None
        sec = step_section(m.group(1), m.group(2))
        if sec is None:
            return f'{m.group(1)}: no step "## {m.group(2)}" in expected.txt'
        want = [x.rstrip() for x in rest if x.strip() and x.strip() != '...']
        bad = subsequence(want, [x.rstrip() for x in sec])
        stats['out'] += 1
        return None if bad is None else f'{m.group(1)} ## {m.group(2)}: line not in output: {want[bad]!r}'
    return None


def check_link(md, text, url):
    if url.startswith(GH):
        m = re.match(re.escape(GH) + r'([^/]+)/([^#]+)(?:#L(\d+)(?:-L(\d+))?)?$', url)
        if not m:
            return f'malformed source link {url}'
        ref, path, a, b = m.groups()
        if ref != REF:
            return f'source link not pinned to {REF}: {url}'
        full = os.path.join(SRC, path)
        if not os.path.exists(full):
            return f'source link to missing path {path}'
        if a and os.path.isfile(full):
            src = lines_of(full)
            a = int(a)
            b = int(b) if b else a + 2
            if a > len(src):
                return f'{path}#L{a}: beyond end of file ({len(src)} lines)'
            ident = re.fullmatch(r'`([A-Za-z_][\w]*)(?:\(\))?`', text.strip())
            if ident and ident.group(1) not in '\n'.join(src[a - 1:b]):
                return f'{path}#L{a}: `{ident.group(1)}` not found on the linked lines'
        return None
    if re.match(r'^[a-z]+:', url) or url.startswith('#'):
        return None
    target = os.path.normpath(os.path.join(os.path.dirname(md), url.split('#')[0]))
    if not os.path.exists(target):
        return f'relative link to missing file {url}'
    return None


def check_figure(md, alt, url):
    svg = os.path.normpath(os.path.join(os.path.dirname(md), url))
    spec = svg[:-4] + '.json'
    if not os.path.isfile(svg) or not os.path.isfile(spec):
        return f'figure {url}: missing SVG or spec; run tools/build_figures.py'
    title = json.load(open(spec, encoding='utf-8')).get('title', '')
    if alt != title:
        return f'figure {url}: image text "{alt}" differs from the spec title "{title}"'
    return None


def check(md):
    text = open(md, encoding='utf-8').read()
    errors = []
    stats = {'c': 0, 'conf': 0, 'out': 0, 'sketch': 0, 'links': 0, 'figures': 0}
    for m in FENCE.finditer(text):
        line = text.count('\n', 0, m.start()) + 1
        err = check_block(m.group(1), m.group(2).rstrip('\n').split('\n'), errors, stats)
        if err:
            errors.append(f'{md}:{line}: {err}')
    prose = FENCE.sub('', text)
    for m in FIGURE.finditer(prose):
        stats['figures'] += 1
        err = check_figure(md, m.group(1), m.group(2))
        if err:
            errors.append(f'{md}: {err}')
    for m in LINK.finditer(FIGURE.sub('', prose)):
        stats['links'] += 1
        err = check_link(md, m.group(1), m.group(2))
        if err:
            errors.append(f'{md}: {err}')
    errors += [f'{md}: {e}' for e in check_structure(md, text, prose, stats)]
    known = known_versions()
    for v, sentence in version_mentions(prose):
        stats['versions'] = stats.get('versions', 0) + 1
        if v not in known:
            errors.append(f'{md}: version {v} does not exist in changes.xml: {sentence}')
    return errors, stats


SPECIAL = re.compile(r'^(导读|已知局限与待核实|修订记录)$')
MIN_CHARS = {'ops': 9000, 'dev': 11000}


def check_structure(md, text, prose, stats):
    """The chapter skeleton from spec: thesis, guide, per-section summary, closing blocks."""
    out = []
    part = os.path.basename(os.path.dirname(os.path.abspath(md)))
    if part not in MIN_CHARS:
        return out
    for need in ('一句话结论', '## 导读', '## 已知局限与待核实', '## 修订记录'):
        if need not in text:
            out.append(f'missing "{need}"')
    sections = re.split(r'^## ', prose, flags=re.M)[1:]
    body = [s for s in sections if not SPECIAL.match(s.split('\n', 1)[0].strip())]
    if not 5 <= len(body) <= 9:
        out.append(f'{len(body)} numbered sections, expected 5-9')
    for s in body:
        title = s.split('\n', 1)[0].strip()
        if '**小结**' not in s:
            out.append(f'section "{title}" has no **小结** line')
    if stats['figures'] < 3:
        out.append(f'{stats["figures"]} figures, expected at least 3')
    if stats['out'] < 4:
        out.append(f'{stats["out"]} quoted lab outputs, expected at least 4')
    need_c = {'ops': 3, 'dev': 8}[part]
    if stats['c'] < need_c:
        out.append(f'{stats["c"]} nginx source excerpts, expected at least {need_c}')
    if stats['sketch'] > 2:
        out.append(f'{stats["sketch"]} 示意 blocks, at most 2')
    chars = len(re.sub(r'\s', '', text))
    stats['chars'] = chars
    if chars < MIN_CHARS[part]:
        out.append(f'{chars} non-space characters, expected at least {MIN_CHARS[part]}')
    lab = re.search(r'labs/((?:ops|dev)-\d\d)', text)
    if lab:
        run = os.path.join(ROOT, 'labs', lab.group(1), 'run.sh')
        script = open(run, encoding='utf-8').read() if os.path.isfile(run) else ''
        if re.search(r'cat\s*>+\s*conf/', script):
            out.append(f'labs/{lab.group(1)}/run.sh writes conf/ at run time; keep configs as files')
        steps = len(re.findall(r'^\s*step\s', script, re.M))
        expects = len(re.findall(r'^\s*expect(?:_match)?\s', script, re.M))
        if script and expects < max(3, (steps + 1) // 2):
            out.append(f'labs/{lab.group(1)}/run.sh has {expects} expect checks for {steps} steps; '
                       f'need at least max(3, steps/2)')
        # "ok -" lines must come from expect/expect_match, never be printed directly
        for n, line in enumerate(script.split('\n'), 1):
            if re.search(r'''\b(echo|printf)\s+["']?(NOT )?OK\b''', line, re.I):
                out.append(f'labs/{lab.group(1)}/run.sh:{n}: prints an ok/NOT OK line itself; use expect')
            # expect "claim" "same" "same" proves nothing: the actual value must be computed
            if re.match(r'''\s*expect(?:_match)?\s+"(?:[^"\\]|\\.)*"\s+(?:"[^"$`\\]*"|'[^']*')\s+["']''',
                        line):
                out.append(f'labs/{lab.group(1)}/run.sh:{n}: expect with a literal actual value; '
                           f'compute it from the lab')
        # absolute paths of the machine the lab ran on must not reach the repository
        exp = os.path.join(ROOT, 'labs', lab.group(1), 'expected.txt')
        for name, body in (('chapter', text),
                           (f'labs/{lab.group(1)}/expected.txt',
                            open(exp, encoding='utf-8').read() if os.path.isfile(exp) else '')):
            hit = re.search(r'/(?:Users|home)/[A-Za-z0-9._-]+', body)
            if hit:
                out.append(f'{name} contains a local path ({hit.group(0)}); normalize it to $LAB')
        out.extend(check_ports(lab.group(1), script))
    return out


def check_ports(lab, script):
    """Every port a lab listens on or requests must be in its own range of 20."""
    part, num = lab.split('-')
    base = (18000 if part == 'ops' else 19000) + int(num) * 20
    texts = [script]
    conf_dir = os.path.join(ROOT, 'labs', lab, 'conf')
    for dirpath, _, files in os.walk(conf_dir):
        for f in files:
            if not f.startswith('.'):
                texts.append(open(os.path.join(dirpath, f), encoding='utf-8', errors='replace').read())
    bad = set()
    for t in texts:
        for p in re.findall(r'(?:127\.0\.0\.1|localhost|\[::1\]):(\d{4,5})\b', t):
            if not base <= int(p) < base + 20:
                bad.add(int(p))
    if bad:
        return [f'labs/{lab} uses ports {sorted(bad)} outside its range {base}-{base + 19}']
    return []


_known = None


def known_versions():
    global _known
    if _known is None:
        # mainline changes.xml plus the stable branch's, which lists 1.30.1..1.30.8
        _known = set()
        for tree in (SRC, SRC.replace('release-1.31.10', 'release-1.30.8')):
            xml = os.path.join(tree, 'docs', 'xml', 'nginx', 'changes.xml')
            if os.path.isfile(xml):
                _known |= set(re.findall(r'<changes ver="([\d.]+)"', open(xml, encoding='utf-8').read()))
    return _known


def version_mentions(prose):
    """(version, sentence) for every x.y.z version number written in the prose."""
    for m in re.finditer(r'(?<![\d.])(1\.\d{1,2}\.\d{1,2})(?![\d.])', prose):
        if prose[max(0, m.start() - 8):m.start()] == 'release-':
            continue
        a = max(prose.rfind('。', 0, m.start()), prose.rfind('\n', 0, m.start())) + 1
        ends = [i for i in (prose.find('。', m.end()), prose.find('\n', m.end())) if i != -1]
        yield m.group(1), prose[a:min(ends) if ends else len(prose)].strip()


def main():
    if not os.path.isdir(SRC) or not os.access(NGINX, os.X_OK):
        sys.exit('run tools/build.sh first (needs .nginx-src/%s and .nginx/sbin/nginx)' % REF)
    args = sys.argv[1:]
    show_versions = '--versions' in args
    args = [a for a in args if a != '--versions']
    files = args or sorted(glob.glob(os.path.join(ROOT, 'ops', '*.md')) +
                                   glob.glob(os.path.join(ROOT, 'dev', '*.md')))
    total = 0
    for md in files:
        errors, s = check(md)
        total += len(errors)
        rel = os.path.relpath(md, ROOT)
        status = 'OK  ' if not errors else 'FAIL'
        print(f'{status} {rel}: {s["c"]} source excerpts, {s["conf"]} configs, {s["out"]} lab outputs, '
              f'{s["links"]} links, {s["sketch"]} sketches, {s["figures"]} figures, '
              f'{s.get("versions", 0)} version mentions, {s.get("chars", 0)} chars')
        if show_versions:
            prose = FENCE.sub('', open(md, encoding='utf-8').read())
            for v, sentence in version_mentions(prose):
                print(f'    [{v}] {sentence[:160]}')
        for e in errors:
            print('    ' + os.path.relpath(e, ROOT) if e.startswith(ROOT) else '    ' + e)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
