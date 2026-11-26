# cloud-03: from Ingress to Gateway API with NGINX Gateway Fabric 2.9.1: the data plane NGF
# provisions, what the API server checks, the nginx config an HTTPRoute becomes, header
# matches, reloads, and an ingress-nginx Ingress converted by ingress2gateway v1.2.0.
# Needs tools/cloud_addons.sh. Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

# gwx CMD...: run CMD in the nginx container of the data plane of Gateway gw
gwx() { k exec deploy/gw-nginx -c nginx -- "$@"; }
# conditions KIND/NAME: the conditions of the first parent in a route's status, sorted
conditions() {
    k get "$1" -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' | sort
}
# until_ok SECONDS CMD...: retry CMD every 0.5 s until it succeeds; fails after SECONDS
until_ok() {
    local end=$(( $(date +%s) + $1 ))
    shift
    until "$@" > /dev/null 2>&1; do
        (( $(date +%s) < end )) || { echo "timed out: $*" >&2; return 1; }
        sleep 0.5
    done
}
has() { gwx sh -c "$1"; }
sighups() { k logs deploy/gw-nginx -c nginx | grep -ac 'signal 1 (SIGHUP) received' || true; }
master() { gwx ps -eo pid,args | awk '/nginx: master/ { print $1 }'; }
workers() { gwx ps -eo pid,args | awk '/nginx: worker process$/ { print $1 }' | sort; }
# upcount: servers in the upstream of Service v1
upcount() { gwx sh -c "sed -n '/^upstream ${NS}_v1_80 /,/^}/p' /etc/nginx/conf.d/http.conf | grep -c 'server [0-9]'"; }
# get CURL-ARGS...: "v1 200" / "v2 200" for an answer from a backend, the status code otherwise
get() {
    local code
    code=$(kx client curl -s --max-time 5 -o /tmp/body -w '%{http_code}' "$@")
    if [[ $code == 200 ]]; then echo "$(kx client head -c 2 /tmp/body) 200"; else echo "$code"; fi
}
conf lab-conf conf/backend.conf
apply k8s/backends.yaml
client

step "a Gateway gets its own data plane"
apply k8s/gateway.yaml
k wait --for=condition=Programmed gateway/gw --timeout=180s > /dev/null
k rollout status deploy/gw-nginx --timeout=180s > /dev/null
until_ok 60 has "grep -q . /etc/nginx/conf.d/http.conf"
until_ok 60 eval '[[ $(sighups) -gt 0 ]]'
echo "provisioned for gw: $(k get deploy,svc -l gateway.networking.k8s.io/gateway-name=gw -o name | sort | tr '\n' ' ')"
echo "image: $(k get deploy gw-nginx -o jsonpath='{.spec.template.spec.containers[?(@.name=="nginx")].image}')"
echo "$(gwx nginx -v 2>&1)"
gwx ps -eo pid,args > out/run/ps.txt
agent=$(awk '$2 == "nginx-agent" { print $1 }' out/run/ps.txt)
awk '{ $1 = ""; sub(/^ /, "") } /master|agent/' out/run/ps.txt
n=$(grep -c 'nginx: worker process$' out/run/ps.txt)
echo "workers: $n, online CPUs of the node: $( (( n == $(gwx nproc) )) && echo the same || echo different)"
from=$(k logs deploy/gw-nginx -c nginx | grep -a 'SIGHUP' | head -1 | sed -E 's/.*received from ([0-9]+).*/\1/')
echo "SIGHUP sent by the agent: $( [[ "$from" == "$agent" ]] && echo yes || echo no)"
expect "one pod runs nginx 1.31.10 and nginx-agent, and the agent reloads nginx" \
    "$(gwx nginx -v 2>&1) $(grep -c nginx-agent out/run/ps.txt) $( [[ "$from" == "$agent" ]] && echo agent)" \
    "nginx version: nginx/1.31.10 1 agent"

step "what the API server checks"
apply k8s/typo-ingress.yaml
echo "Ingress typo stored with annotations: $(k get ingress typo -o go-template='{{range $k, $v := .metadata.annotations}}{{$k}}={{$v}}{{"\n"}}{{end}}' | grep -v last-applied | tr '\n' ' ')"
f=$(k apply -f k8s/typo-field.yaml 2>&1 || true)
e=$(k apply -f k8s/typo-enum.yaml 2>&1 || true)
sed -E 's/^Error from server \(BadRequest\): error when creating "[^"]+": //' <<< "$f"
grep -a 'Unsupported value' <<< "$e" | sed -E 's/^\* //'
expect "a misspelled annotation is stored; a misspelled field and a wrong enum value are rejected" \
    "$(k get ingress typo -o name) $(grep -c 'unknown field "spec.rules\[0\].backendRef"' <<< "$f") $(grep -c 'Unsupported value: "Prefix"' <<< "$e")" \
    "ingress.networking.k8s.io/typo 1 1"

step "an HTTPRoute in nginx.conf"
k rollout status deploy/v1 --timeout=180s > /dev/null
k rollout status deploy/v2 --timeout=180s > /dev/null
apply k8s/route.yaml
until_ok 60 has "grep -q split_clients /etc/nginx/conf.d/http.conf"
until_ok 60 eval "conditions httproute/shop | grep -q '^ResolvedRefs='"
gwx nginx -T 2> /dev/null > out/run/T1.txt
echo "locations:"
grep -E '^\s*location ' out/run/T1.txt | grep -v readyz | sed -E 's/^\s+/  /; s/ \{$//' | sort
echo "upstreams: $(grep -E '^upstream ' out/run/T1.txt | awk '{ print $2 }' | sort | tr '\n' ' ')"
up=$(sed -n "/^upstream ${NS}_v1_80 /,/^}/p" out/run/T1.txt)
echo "upstream ${NS}_v1_80: $(grep -E 'random|zone' <<< "$up" | sed -E 's/^\s+//; s/ [0-9]+k;$/ ...;/' | tr '\n' ' ')"
servers=$(grep -oE 'server [0-9.]+:80' <<< "$up" | awk '{ print $2 }' | sed 's/:80$//' | sort | tr '\n' ' ')
podips=$(k get pods -l app=v1 -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort | tr '\n' ' ')
echo "its servers are the v1 pod IPs: $( [[ "$servers" == "$podips" ]] && echo yes || echo no)"
sed -n '/^split_clients/,/^}/p' out/run/T1.txt | sed -E 's/\$group_[a-zA-Z0-9_]+/$group_.../'
conditions httproute/shop
G=$(k get svc gw-nginx -o jsonpath='{.spec.clusterIP}')
echo "GET /missing: $(kx client curl -s -o /dev/null -w '%{http_code}' "http://$G/missing")"
expect "upstream servers are pod IPs; weights are split_clients; a missing backend is a status and a 500" \
    "$( [[ "$servers" == "$podips" ]] && echo pods) $(grep -c '^split_clients \$request_id' out/run/T1.txt) $(conditions httproute/shop | grep -c 'ResolvedRefs=False BackendNotFound') $(kx client curl -s -o /dev/null -w '%{http_code}' "http://$G/missing")" \
    "pods 1 1 500"

step "80/20 weights over 1000 requests"
kx client sh -c "for i in \$(seq 1000); do curl -s --max-time 5 http://$G/ || echo FAILED; done" \
    | cut -d- -f1 | sort | uniq -c | awk '{ print $2 ": " $1 }' > out/run/split.txt
v2=$(awk '$1 == "v2:" { print $2 }' out/run/split.txt)
echo "answers: $(awk '{ n += $2 } END { print n }' out/run/split.txt), from: $(awk '{ sub(":", "", $1); print $1 }' out/run/split.txt | tr '\n' ' ' | sed 's/ $//')"
echo "v2 share between 14 % and 26 %: $( (( v2 >= 140 && v2 <= 260 )) && echo yes || echo no)"
expect "split_clients on \$request_id keeps close to 80/20" \
    "$(awk '{ n += $2 } END { print n }' out/run/split.txt) $( (( v2 >= 140 && v2 <= 260 )) && echo yes)" "1000 yes"

step "a header match does not fall back to another path"
echo "/api/x without x-env: $(get "http://$G/api/x")"
echo "/api/x with x-env: canary: $(get -H 'x-env: canary' "http://$G/api/x")"
echo "/other without x-env: $(get "http://$G/other" | awk '{ print $2 }')"
echo "matches.json: $(gwx cat /etc/nginx/conf.d/matches.json)"
before="$(get "http://$G/api/x") $(get -H 'x-env: canary' "http://$G/api/x")"
apply k8s/route-fallback.yaml
until_ok 60 has "grep -q any /etc/nginx/conf.d/matches.json"
echo "with PathPrefix /api added to the / rule:"
echo "matches.json: $(gwx cat /etc/nginx/conf.d/matches.json)"
echo "/api/x without x-env: $(get "http://$G/api/x" | awk '{ print $2 }')"
echo "/api/x with x-env: canary: $(get -H 'x-env: canary' "http://$G/api/x")"
expect "without a rule registered under /api the request gets 404; with one it is routed" \
    "$before $(get "http://$G/api/x" | awk '{ print $2 }') $(get -H 'x-env: canary' "http://$G/api/x")" \
    "404 v2 200 200 v2 200"

step "a route change is a reload"
h0=$(sighups) m0=$(master) w0=$(workers)
apply k8s/route.yaml
until_ok 60 eval '! has "grep -q any /etc/nginx/conf.d/matches.json"'
until_ok 30 eval '[[ $(sighups) -gt $h0 ]]'
sleep 2
h1=$(sighups) m1=$(master) w1=$(workers)
echo "SIGHUP: +$(( h1 - h0 )), master PID unchanged: $( [[ $m0 == "$m1" ]] && echo yes || echo no), workers all new: $( [[ -z $(comm -12 <(echo "$w0") <(echo "$w1")) ]] && echo yes || echo no)"
expect "the agent reloads nginx for a route change" \
    "$(( h1 - h0 )) $( [[ $m0 == "$m1" ]] && echo same) $( [[ -z $(comm -12 <(echo "$w0") <(echo "$w1")) ]] && echo new)" "1 same new"

step "an endpoint change is a reload too"
size=$(kx client stat -c %s /usr/sbin/nginx)
kx client curl -s -o /dev/null --max-time 60 -w '%{http_code} %{size_download}\n' "http://$G/big" > out/run/big.txt & d=$!
sleep 2
h0=$(sighups) m0=$(master) w0=$(workers)
k scale deploy/v1 --replicas=3 > /dev/null
k rollout status deploy/v1 --timeout=180s > /dev/null
t0=$(date +%s)
until_ok 30 eval '[[ $(upcount) == 3 ]]'
echo "the new pod in the upstream within 10 s of being ready: $( (( $(date +%s) - t0 <= 10 )) && echo yes || echo no)"
until_ok 30 eval '[[ $(sighups) -gt $h0 ]]'
sleep 1
draining=$(gwx ps -eo args | grep -c 'worker process is shutting down' || true)
echo "SIGHUP: +$(( $(sighups) - h0 )), master PID unchanged: $( [[ $m0 == "$(master)" ]] && echo yes || echo no)"
echo "an old worker still serving the download: $( (( draining > 0 )) && echo yes || echo no)"
echo "worker_shutdown_timeout in the generated config: $(gwx nginx -T 2> /dev/null | grep -c worker_shutdown_timeout || true)"
wait $d || true
read -r code got < out/run/big.txt
echo "download: $code, all $( [[ $got == "$size" ]] && echo "$((size / 1024 / 1024)) MB" || echo "but $got of $size bytes")"
expect "scaling v1 reloads nginx; the download in flight finishes on the old worker" \
    "$(( $(sighups) - h0 )) $( (( draining > 0 )) && echo draining) $code $( [[ $got == "$size" ]] && echo complete)" \
    "1 draining 200 complete"

step "ingress2gateway on an ingress-nginx Ingress"
rc=0
ingress2gateway print --providers ingress-nginx --input-file k8s/ingress-nginx.yaml --no-color \
    > out/run/i2g.yaml 2> out/run/i2g.err || rc=$?
echo "exit code: $rc"
echo "warnings:"
grep -a '^│  ' out/run/i2g.err | grep -avE '^│  +(source|object):' | sed -E 's/^│  +/  /' | sort -u
ingress2gateway print --providers ingress-nginx --input-file k8s/ingress-nginx.yaml --no-color -o json \
    2> /dev/null > out/run/i2g.json
python3 i2g.py summary out/run/i2g.json
expect "exit code 0 while 4 annotations are dropped" \
    "$rc $(grep -acE 'Unsupported annotation|Failed to apply' out/run/i2g.err | awk '{ print ($1 > 0) }') $(grep -aoE 'nginx.ingress.kubernetes.io/(limit-rps|configuration-snippet|proxy-body-size|rewrite-target)' out/run/i2g.err | sort -u | wc -l | tr -d ' ')" \
    "0 1 4"

step "applying the conversion"
k apply -f out/run/i2g.yaml > /dev/null
k wait --for=condition=Programmed gateway/nginx --timeout=180s > /dev/null
k rollout status deploy/nginx-nginx --timeout=180s > /dev/null
R=httproute/shop-shop-example-com
until_ok 60 eval "conditions $R | grep -q '^Accepted='"
until_ok 60 eval "conditions $R | grep -q '^ResolvedRefs='"
conditions $R | sed -E 's/: All rules are invalid: .*/: All rules are invalid: .../'
echo "invalid paths: $(conditions $R | grep -oE 'path.value: Invalid value: "[^"]+"' | sed -E 's/.*"(.*)"/\1/' | tr '\n' ' ')"
N=$(k get svc nginx-nginx -o jsonpath='{.spec.clusterIP}')
code1=$(kx client curl -s -o /dev/null -w '%{http_code}' -H 'Host: shop.example.com' "http://$N/api/x")
echo "GET /api/x with Host shop.example.com: $code1"
python3 i2g.py fix out/run/i2g.json > out/run/i2g-fixed.json
k apply -f out/run/i2g-fixed.json > /dev/null
until_ok 60 eval "conditions $R | grep -q '^Accepted=True'"
echo "with the paths as PathPrefix:"
conditions $R
until_ok 30 eval "[[ \$(kx client curl -s -o /dev/null -w '%{http_code}' -H 'Host: shop.example.com' http://$N/api/x) == 200 ]]"
kx client curl -s -D - -o /dev/null -H 'Host: shop.example.com' -H 'Origin: https://a.example' "http://$N/api/x" \
    | tr -d '\r' | grep -iE '^HTTP/|^access-control-allow-origin' > out/run/cors.txt
cat out/run/cors.txt
expect "the converted route is rejected for its regex; with PathPrefix it is accepted and its timeouts are ignored" \
    "$code1 $(conditions $R | grep -c 'Accepted=True UnsupportedField: .*spec.rules\[0\].timeouts: Forbidden: Timeouts') $(grep -ci '^access-control-allow-origin: https://a.example' out/run/cors.txt)" \
    "404 1 1"
