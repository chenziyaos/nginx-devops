# cloud-07: one access check written three ways, njs (js_access, QuickJS engine), Rust
# (the "curl" example of ngx-rust) and C, loaded into the same nginx: their answers, what
# a reload does with a changed script and with a new .so, an exception in njs, and how
# each module parses its directive. Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

until_ok() {
    local end=$(( $(date +%s) + $1 ))
    shift
    until "$@" > /dev/null 2>&1; do
        (( $(date +%s) < end )) || { echo "timed out: $*" >&2; return 1; }
        sleep 0.5
    done
}
MODS=/usr/lib/nginx/modules
nx() { k exec ext -- "$@"; }
addr() { k get pod ext -o jsonpath='{.status.podIP}'; }
# code PATH UA [PORT]: the status code of GET PATH with that User-Agent
code() {
    kx client curl -s --max-time 5 -o /dev/null -w '%{http_code}' -A "$2" "http://$(addr):${3:-80}$1"
}
# cm NGINX-CONF NOCURL-JS: (re)write the ConfigMap ext-conf
cm() {
    k create configmap ext-conf --from-file=nginx.conf="$1" --from-file=nocurl.js="$2" \
        --from-file=throw.js=conf/throw.js --dry-run=client -o yaml | k apply -f - > /dev/null
}
# sync: a changed annotation makes kubelet update the pod's volumes now (cloud-04 §2)
sync() { k annotate pod ext lab/sync="$(date +%s%N)" --overwrite > /dev/null; }
reload() {
    nx nginx -c /etc/nginx/conf/nginx.conf -s reload 2> /dev/null
    until_ok 30 eval '[[ $(nx ps -eo args | grep -c "^nginx: worker process is shutting down") == 0 ]]'
    sleep 1
}
worker() { nx ps -eo pid,args | awk '$2 == "nginx:" && $3 == "worker" && NF == 4 { print $1 }'; }
# maps: the module files mapped into the master (pid 1; the workers are its forks and run
# as nginx, whose /proc/PID/maps kubectl exec may not read), " (deleted)" for a replaced file
maps() {
    nx cat /proc/1/maps | grep -o "$MODS/.*" | sed "s#$MODS/##" | sort -u | tr '\n' ';'
}
plainlog() { sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: (\*[0-9]+ )?/\1 /; s/, client:.*//'; }

cm conf/nginx.conf conf/nocurl.js
apply k8s/pod.yaml
client
ready app=ext

step "three modules in one image"
echo "module                      as built   stripped"
nx cat /usr/share/nginx-ext/sizes.txt \
    | awk '{ printf "%-28s %6d KB  %6d KB\n", $1, ($2 + 512) / 1024, ($3 + 512) / 1024 }'
echo "lines: nocurl.js $(wc -l < conf/nocurl.js), curl.rs $(nx wc -l /usr/share/nginx-ext/curl.rs | awk '{ print $1 }'), ngx_http_nocurl_module.c $(nx wc -l /usr/share/nginx-ext/ngx_http_nocurl_module.c | awk '{ print $1 }')"
expect "the njs module was built with QuickJS-NG, and all three load" \
    "$(nx nginx -t -c /etc/nginx/conf/nginx.conf 2>&1 | grep -c 'test is successful')" "1"

step "the same answers from all three"
for p in /js /rust /c; do
    echo "$p: curl/8.14.1 -> $(code $p curl/8.14.1), Mozilla/5.0 -> $(code $p Mozilla/5.0), Wget/1.25 -> $(code $p Wget/1.25)"
done
expect "403 for curl, the backend's 200 for the others, in each" \
    "$(for p in /js /rust /c; do echo -n "$(code $p curl/8.14.1)/$(code $p Mozilla/5.0) "; done)" \
    "403/200 403/200 403/200 "

step "a changed script takes effect at the next reload"
cm conf/nginx.conf conf/nocurl-v2.js
sync
until_ok 60 eval "nx grep -q Wget /etc/nginx/conf/nocurl.js"
before=$(code /js Wget/1.25)
echo "nocurl.js in the pod now refuses Wget too; before the reload /js -> $before"
reload
echo "after the reload: /js -> $(code /js Wget/1.25), /c -> $(code /c Wget/1.25)"
expect "js_import compiles the file when the config is loaded, not per request" \
    "$before $(code /js Wget/1.25) $(code /c Wget/1.25)" "200 403 200"

step "a new .so under the same path: the reload keeps the old code"
nx sh -c "cp $MODS/nocurl-451.so /tmp/new.so && mv /tmp/new.so $MODS/ngx_http_nocurl_module.so"
echo "ngx_http_nocurl_module.so is the 451 build now: $(nx cmp -s $MODS/ngx_http_nocurl_module.so $MODS/nocurl-451.so && echo yes)"
w0=$(worker)
reload
echo "after the reload: new worker $( [[ "$(worker)" != "$w0" ]] && echo yes || echo no), /c -> $(code /c curl/8.14.1)"
echo "mapped by the master: $(maps)"
expect "dlopen() of a file name the master has open returns the copy it has" \
    "$( [[ "$(worker)" != "$w0" ]] && echo new) $(code /c curl/8.14.1)" "new 403"

step "another file name: loaded, and still the old code"
cm conf/nginx-451.conf conf/nocurl-v2.js
sync
until_ok 60 eval "nx grep -q nocurl-451 /etc/nginx/conf/nginx.conf"
reload
echo "load_module $MODS/nocurl-451.so, after the reload: /c -> $(code /c curl/8.14.1)"
echo "mapped by the master: $(maps)"
expect "the new file is mapped, but its ngx_http_nocurl_module binds to the one loaded first" \
    "$(code /c curl/8.14.1) $(maps | grep -c 'nocurl-451.so')" "403 1"

step "a restart runs the new code"
nx nginx -c /etc/nginx/conf/nginx.conf -s stop 2> /dev/null || true
until_ok 90 eval '[[ $(k get pod ext -o jsonpath="{.status.containerStatuses[0].restartCount}") == 1 ]] && [[ $(code /c curl/8.14.1) != 000 ]]'
echo "restarted container: /c -> $(code /c curl/8.14.1), /js Wget -> $(code /js Wget/1.25)"
echo "mapped by the master: $(maps)"
expect "a new master loads every module from scratch" "$(code /c curl/8.14.1)" "451"

step "an exception in njs ends the request with 500"
w0=$(worker)
echo "/buggy -> $(code /buggy curl/8.14.1)"
k logs ext | grep -a 'js call exception' | tail -1 | plainlog
echo "same worker afterwards: $( [[ "$(worker)" == "$w0" ]] && echo yes || echo no), /js -> $(code /js curl/8.14.1)"
expect "the call fails, the access handler returns 500, the worker goes on" \
    "$(code /buggy curl/8.14.1) $( [[ "$(worker)" == "$w0" ]] && echo same)" "500 same"

step "how each module parses its directive"
for f in typo-rust typo-c; do
    k exec -i ext -- sh -c "cat > /tmp/$f.conf" < "conf/$f.conf"
    echo "== $f.conf: $(awk '/curl yes;/ { print $1, $2 }' "conf/$f.conf")"
    nx nginx -t -c "/tmp/$f.conf" 2>&1 | grep '^nginx: ' | sed -E 's/^nginx: //' || true
done
# a second nginx in the pod; its output goes to /dev/null, or kubectl exec waits for it
nx sh -c "nginx -c /tmp/typo-rust.conf > /dev/null 2>&1"
until_ok 10 eval '[[ $(code / Mozilla/5.0 8090) == 200 ]]'
rust=$(code / curl/8.14.1 8090)
echo "typo-rust.conf running: curl/8.14.1 -> $rust"
nx nginx -c /tmp/typo-rust.conf -s stop 2> /dev/null
expect "the Rust example takes any other value as off; ngx_conf_set_flag_slot rejects it" \
    "$(nx nginx -t -c /tmp/typo-rust.conf 2>&1 | grep -c 'test is successful') $rust $(nx nginx -t -c /tmp/typo-c.conf 2>&1 | grep -c '^nginx: .*invalid value "yes"')" \
    "1 200 1"
