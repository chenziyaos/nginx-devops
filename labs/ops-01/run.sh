# ops-01: what the binary says about itself, which modules it has, and how -p/-c/-e/-g/-t/-s
# behave. Expected values come from the source (see HYPOTHESES.md), not from a previous run.
. "$(dirname "$0")/../lib.sh"

# the machine's paths never reach expected.txt
n() { sed -e "s#$LAB/#\$LAB/#g" -e "s#$ROOT/#\$ROOT/#g" -e "s#$ROOT#\$ROOT#g" \
          -E -e 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /'; }

# load_module paths are relative to the prefix; the lab's prefix is this directory
ln -sfn ../../.nginx/modules modules

step "version and configure arguments"
"$NGINX" -v 2>&1
"$NGINX" -V 2>&1 | n | sed -E 's/^built by .*/built by <compiler>/; s/^(built with OpenSSL [0-9]+)\.[^ ]+ .*/\1.x/' \
    | tee out/run/V.txt
src_ver=$(sed -n 's/^#define NGINX_VERSION *"\(.*\)"/\1/p' ../../.nginx-src/release-1.31.9/src/core/nginx.h)
expect "-v prints NGINX_VERSION from src/core/nginx.h" "$("$NGINX" -v 2>&1)" "nginx version: nginx/$src_ver"
missing=""
for f in $(grep -oE -- '--with-[a-z0-9_-]+' ../../tools/build.sh); do
    grep -q -- "$f" out/run/V.txt || missing+="$f "
done
expect "every --with option of tools/build.sh is in the configure arguments" "${missing:-none}" "none"

step "what each branch received since it was cut"
# change types per release line, counted from each branch's own changes.xml
types() {
    python3 - "$1" "$2" <<'PY'
import re, sys
from collections import Counter
x = open(sys.argv[1], encoding='utf-8').read()
c = Counter()
for m in re.finditer(r'<changes ver="%s\.\d+".*?</changes>' % re.escape(sys.argv[2]), x, re.S):
    c.update(re.findall(r'<change type="(\w+)"', m.group(0)))
print(sys.argv[2] + '.x:', ' '.join(f'{t} {c[t]}' for t in ('feature', 'change', 'bugfix', 'security')))
PY
}
s130=$(types ../../.nginx-src/release-1.30.7/docs/xml/nginx/changes.xml 1.30); echo "$s130"
s131=$(types ../../.nginx-src/release-1.31.9/docs/xml/nginx/changes.xml 1.31); echo "$s131"
expect "the stable branch gets no features" "$(grep -o 'feature [0-9]*' <<< "$s130")" "feature 0"

step "modules compiled in"
mods=../../.nginx-src/release-1.31.9/objs/ngx_modules.c
for m in ngx_http_tunnel_module ngx_http_proxy_module ngx_http_realip_module ngx_http_json_module \
         ngx_http_dav_module ngx_http_hello_module; do
    printf '%-24s %s\n' "$m" "$(grep -q "^    &$m,$" $mods && echo built-in || echo no)"
done | tee out/run/mods.txt
expect "default-on modules and --with modules are built in; dav (default off) and the dynamic hello are not" \
    "$(awk '{ print $2 }' out/run/mods.txt | tr '\n' ' ')" "built-in built-in built-in built-in no no "
t conf/dav.conf
expect "a directive of a module that is not built is an unknown directive" \
    "$(t conf/dav.conf | head -1)" '[emerg] unknown directive "dav_methods" in $LAB/conf/dav.conf:8'

step "dynamic modules"
t conf/hello-noload.conf | head -1
t conf/hello-badpath.conf | head -1 | sed -E 's/failed \(.*\) in /failed (...) in /'
t conf/hello.conf
start conf/hello.conf
body=$(curl -s http://127.0.0.1:18021/); echo "GET / -> $body"
stop
expect "without load_module the directive is unknown; with it the module answers" \
    "$(t conf/hello-noload.conf | head -1 | grep -o 'unknown directive "hello"') / $body" \
    'unknown directive "hello" / hello from a dynamic module'

step "a fresh prefix"
P=$LAB/out/run/p
mkdir -p "$P/conf"
cp conf/nginx.conf "$P/conf/"
echo "before: $(ls "$P" | tr '\n' ' ')"
"$NGINX" -p "$P/" -t 2>&1 | n || true
mkdir "$P/logs"
"$NGINX" -p "$P/" -t 2>&1 | n || true
echo "after -t: $(ls "$P" | tr '\n' ' ')"
expect "-t creates the *_temp directories but not logs/" \
    "$(ls "$P" | tr '\n' ' ')" "client_body_temp conf fastcgi_temp logs proxy_temp scgi_temp uwsgi_temp "

step "nginx -t leaves an empty pid file"
echo "pid file size after -t: $(wc -c < "$P/logs/nginx.pid" | tr -d ' ')"
"$NGINX" -p "$P/" -s reload 2>&1 | n || true
expect "-t creates the pid file without writing a pid, so -s finds an empty one" \
    "$(wc -c < "$P/logs/nginx.pid" | tr -d ' ') $("$NGINX" -p "$P/" -s reload 2>&1 | n | grep -c 'invalid PID number ""' || true)" "0 1"

step "-s finds the master through the pid file"
start
master=$(master_pid); echo "master running: $(kill -0 "$master" 2>/dev/null && echo yes || echo no)"
ngx -s reopen && echo "-s reopen: exit 0"
ngx -s restart 2>&1 || true
ngx -s stop
for i in $(seq 50); do kill -0 "$master" 2>/dev/null || break; sleep 0.1; done
gone=$(kill -0 "$master" 2>/dev/null && echo no || echo yes)
echo "master gone after -s stop: $gone, pid file left: $([[ -e logs/nginx.pid ]] && echo yes || echo no)"
expect "stop ends the master and it removes its pid file" "$gone $([[ -e logs/nginx.pid ]] && echo yes || echo no)" "yes no"

step "-g is parsed before the config file"
ngx -t -c conf/with-pid.conf 2>&1 | n || true
expect "a pid in the file collides with the pid given by -g" \
    "$(ngx -t -c conf/with-pid.conf 2>&1 | n | head -1)" \
    'nginx: [emerg] "pid" directive is duplicate in $LAB/conf/with-pid.conf:2'

step "-t -q prints errors only"
quiet=$(ngx -t -q -c conf/nginx.conf 2>&1; echo "rc=$?")
echo "good config: [$quiet]"
ngx -t -q -c conf/dav.conf 2>&1 | n || true
expect "-q drops the two success lines and keeps the exit code" "$quiet" "rc=0"

step "defaults compiled into the binary"
"$NGINX" -h 2>&1 | n | grep 'default'
expect "the default prefix is --prefix, the config and error log are relative to it" \
    "$("$NGINX" -h 2>&1 | n | grep -c -e 'default: \$ROOT/.nginx/)' -e 'default: logs/error.log)' -e 'default: conf/nginx.conf)')" "3"
