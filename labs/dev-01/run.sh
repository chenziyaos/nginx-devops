# dev-01: the source tree, what configure generates, the module list, and the debug log.
# Expected values come from the source (see HYPOTHESES.md), not from a previous run.
. "$(dirname "$0")/../lib.sh"

SRC=$ROOT/.nginx-src/release-1.31.9
U=http://127.0.0.1:19020

# drop timestamps, pids and pointers from debug lines
dbg() {
    sed -E 's/^[0-9\/]+ [0-9:]+ \[debug\] [0-9]+#[0-9]+: //; s/0{0,8}[0-9A-F]{12,16}/PTR/g; s/[0-9]{9,}/T/g; s/:[0-9]{4,5} fd:/:PORT fd:/'
}

step "the source tree"
for d in core event event/modules event/quic http http/modules http/v2 http/v3 stream mail os/unix; do
    printf '%-14s %3d .c files %6d lines\n' "src/$d" \
        "$(ls "$SRC/src/$d"/*.c | wc -l)" "$(cat "$SRC/src/$d"/*.c | wc -l)"
done | tee out/run/tree.txt
expect "http and its modules are the largest part" \
    "$(sort -k5,5n out/run/tree.txt | tail -2 | awk '{ print $1 }' | sort | tr '\n' ' ')" "src/http src/http/modules "

step "what configure generated"
ls "$SRC/objs" | grep -vE '^(src|nginx|.*\.so|.*\.o|ngx_.*_module_modules\.c)$' | tr '\n' ' '; echo
grep -E '^#define (NGX_DEBUG|NGX_COMPAT|NGX_HAVE_KQUEUE|NGX_HAVE_EPOLL|NGX_HTTP_V2|NGX_CONTROL_API|NGX_PREFIX)\b' \
    "$SRC/objs/ngx_auto_config.h" -A0 | sed "s#$ROOT/#\$ROOT/#" | sort
expect "--with-debug becomes NGX_DEBUG in ngx_auto_config.h" \
    "$(grep -A1 'ifndef NGX_DEBUG$' "$SRC/objs/ngx_auto_config.h" | tail -1 | tr -s ' ')" "#define NGX_DEBUG 1"

step "the module list"
mods=$(sed -n '/^ngx_module_t \*ngx_modules\[\] = {/,/^};/p' "$SRC/objs/ngx_modules.c" | grep -oE 'ngx_[a-z0-9_]+_module')
echo "modules: $(wc -l <<< "$mods" | tr -d ' ')"
expect "92 modules in this build" "$(wc -l <<< "$mods" | tr -d ' ')" "92"
echo "first: $(head -6 <<< "$mods" | tr '\n' ' ')"
echo "http filters, in array order:"
grep '_filter_module$' <<< "$mods" | grep '^ngx_http' | sed 's/^/  /' | tee out/run/filters.txt
order=$(sed -n '/# the filter order is important/,/ngx_module_type=HTTP_FILTER/p' "$SRC/auto/modules" \
    | grep -oE 'ngx_http_[a-z0-9_]+_filter' | sed 's/$/_module/')
missing_order=$(sed 's/^  //' out/run/filters.txt | while read -r f; do grep -n "^$f$" <<< "$order" | cut -d: -f1; done | tr '\n' ' ')
echo "positions in the auto/modules comment: $missing_order"
expect "the array keeps the filter order written in auto/modules" \
    "$(tr ' ' '\n' <<< "$missing_order" | grep . | sort -n -c 2>&1 && echo sorted)" "sorted"

step "module types"
python3 - "$SRC" <<'PY' | tee out/run/types.txt
import collections, os, re, sys
src = sys.argv[1]
names = re.findall(r'&(ngx_\w+_module),', open(os.path.join(src, 'objs/ngx_modules.c')).read())
defs = {}
for root, _, files in os.walk(os.path.join(src, 'src')):
    for f in files:
        if f.endswith('.c'):
            text = open(os.path.join(root, f), errors='replace').read()
            for m in re.finditer(r'^ngx_module_t\s+(ngx_\w+)\s*=\s*\{(.*?)^\};', text, re.M | re.S):
                t = re.search(r'\b(NGX_[A-Z]+_MODULE)\b', m.group(2))
                defs[m.group(1)] = t.group(1) if t else '?'
c = collections.Counter(defs.get(n, 'not found') for n in names)
for t, n in sorted(c.items(), key=lambda x: -x[1]):
    print(f'{t:20} {n}')
PY
expect "five types are built; mail modules exist in src/mail but need --with-mail" \
    "$(awk '{ print $1 }' out/run/types.txt | sort | tr '\n' ' ') $(awk '{ s += $2 } END { print s }' out/run/types.txt)" \
    "NGX_CONF_MODULE NGX_CORE_MODULE NGX_EVENT_MODULE NGX_HTTP_MODULE NGX_STREAM_MODULE  92"

step "the debug log of one request"
start
curl -s $U/ > /dev/null
sleep 0.3
stop
echo "debug lines for one GET /: $(grep -ac '\[debug\]' logs/debug.log)"
grep -aE 'accept:|http request line|http header done|phase: |internal redirect|http output filter|http copy filter: "|http postpone filter|http write filter: |http finalize request|set http keepalive|http close request' logs/debug.log \
    | dbg | tee out/run/req.txt
expect "the phases run twice: index turns / into an internal redirect to /index.html" \
    "$(grep -c 'content phase: 14' out/run/req.txt) $(grep -c 'generic phase: 0' out/run/req.txt)" "2 1"

step "the phase engine, rebuilt from the module list"
# which module registers a handler in which phase, in ngx_modules[] order; the engine puts
# each phase's handlers in reverse order and adds find-config, post-rewrite, post-access
python3 - "$SRC" <<'PY' | tee out/run/engine.txt
import os, re, sys
src = sys.argv[1]
names = re.findall(r'&(ngx_\w+_module),', open(os.path.join(src, 'objs/ngx_modules.c')).read())
files = {}
for root, _, fs in os.walk(os.path.join(src, 'src/http')):
    for f in fs:
        if f.endswith('.c'):
            t = open(os.path.join(root, f), errors='replace').read()
            for m in re.finditer(r'^ngx_module_t\s+(ngx_\w+)\s*=', t, re.M):
                files[m.group(1)] = t
reg = {}
for n in names:
    if n in files and n != 'ngx_http_module':
        for p in re.findall(r'cmcf->phases\[NGX_HTTP_(\w+)_PHASE\]\.handlers', files[n]):
            reg.setdefault(p, []).append(n.replace('ngx_http_', '').replace('_module', ''))
i = 0
for p in ('POST_READ', 'SERVER_REWRITE', 'FIND_CONFIG', 'REWRITE', 'POST_REWRITE', 'PREACCESS',
          'ACCESS', 'POST_ACCESS', 'PRECONTENT', 'CONTENT'):
    hs = list(reversed(reg.get(p, []))) or ['(core checker)']
    for h in hs:
        print(f'{i:2} {p:15} {h}')
        i += 1
PY
want=$(awk '$2 != "FIND_CONFIG" { print $1 + 0 }' out/run/engine.txt | sort -n | uniq | tr '\n' ' ')
got=$(grep -oE 'phase: [0-9]+' out/run/req.txt | awk '{ print $2 }' | sort -n | uniq | tr '\n' ' ')
echo "indexes in the debug log: $got"
expect "the debug log shows every handler index of the rebuilt engine except find-config" "$got" "$want"

step "debug_connection"
start conf/debug-connection.conf
curl -s http://127.0.0.1:19021/ > /dev/null
curl -s 'http://[::1]:19021/' > /dev/null
sleep 0.3
stop
# connection *1 is the 127.0.0.1 request, *2 the [::1] one
c1=$(grep -a '\[debug\]' logs/dc.log | grep -c ': \*1 ' || true)
c2=$(grep -a '\[debug\]' logs/dc.log | grep -c ': \*2 ' || true)
echo "127.0.0.1 (*1) debug lines > 50: $([[ $c1 -gt 50 ]] && echo yes || echo no)"
echo "[::1] (*2) debug lines: $c2"
grep -a 'accept: ' logs/dc.log | dbg | sed -E 's/^\[debug\] //'
expect "only the listed address gets debug lines; the error_log level stays info for the rest" \
    "$([[ $c1 -gt 50 ]] && echo many) $c2" "many 0"

step "one process for a debugger"
"$NGINX" -p "$LAB/" -e logs/error.log -g "pid logs/nginx.pid;" -c conf/single.conf &
for i in $(seq 50); do [[ -s logs/nginx.pid ]] && break; sleep 0.1; done
p=$(master_pid)
echo "GET / -> $(curl -s http://127.0.0.1:19022/)"
echo "children of the nginx process: $(pgrep -P "$p" | wc -l | tr -d ' ')"
echo "title: $(ps -o command= -p "$p" | sed "s#$NGINX#\$NGINX#; s#$LAB/#\$LAB/#; s/ *$//")"
expect "master_process off: one process serves requests, nothing is forked" \
    "$(pgrep -P "$p" | wc -l | tr -d ' ') $(curl -s http://127.0.0.1:19022/)" "0 dev-01"
kill -TERM "$p"
wait
rm -f logs/nginx.pid
