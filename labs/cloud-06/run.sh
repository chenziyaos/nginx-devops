# cloud-06: observing nginx in the cluster: stub_status through nginx-prometheus-exporter,
# JSON logs on stdout and what the container runtime does with long lines, a request id
# and a traceparent across two hops, and the control API's view of exiting workers.
# Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

until_ok() {
    local end=$(( $(date +%s) + $1 ))
    shift
    until "$@" > /dev/null 2>&1; do
        (( $(date +%s) < end )) || { echo "timed out: $*" >&2; return 1; }
        sleep 0.5
    done
}
EDGE=http://edge.$NS.svc.cluster.local
addr() { k get pod "$1" -o jsonpath='{.status.podIP}'; }
# metrics: the exporter's /metrics, nginx_* lines only
metrics() { kx client curl -s --max-time 5 "http://$(addr edge):9113/metrics" | grep '^nginx_'; }
metric() { metrics | awk -v m="$1" '$1 == m { print $2 }'; }
# get [CURL-ARGS...]: a request to the edge, from the client pod
get() { kx client curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$@" "http://$(addr edge)/"; }
# field POD KEY [N]: KEY of the N-th last JSON line in POD's nginx log (default the last)
field() {
    k logs "$1" -c nginx | grep -a '^{' | tail -"${3:-1}" | head -1 \
        | python3 -c "import json, sys; print(json.load(sys.stdin)['$2'])"
}
ctl() { k exec edge -c nginx -- curl -s --unix-socket /run/ctl/nginx.sock "http://localhost$1"; }

conf edge-conf conf/edge.conf
conf app-conf conf/app.conf
apply k8s/pods.yaml
client
ready app=edge
ready app=app

# rec ID: the records of the edge's log file on the node whose JSON has request id ID,
# as "<stream> <P|F> <bytes>"; P is a partial record that the next one continues
rec() {
    docker exec "$node" sh -c "cat /var/log/pods/${NS}_edge_$(k get pod edge -o jsonpath='{.metadata.uid}')/nginx/*.log" \
        | awk -v id="$1" 'index($0, id) || cont { print $2, $3, length($0) - length($1) - length($2) - length($3) - 3; cont = ($3 == "P") }'
}
node=$(k get pod edge -o jsonpath='{.spec.nodeName}')

step "the metrics the exporter makes from stub_status"
kx client curl -s --max-time 5 "http://$(addr edge):9113/metrics" | grep '^# TYPE nginx_' | grep -v build_info
echo "nginx_up $(metric nginx_up)"
expect "seven stub_status numbers become three counters and four gauges, plus nginx_up" \
    "$(kx client curl -s --max-time 5 "http://$(addr edge):9113/metrics" | grep '^# TYPE nginx_' | grep -v build_info | awk '{ n[$4]++ } END { print "counter=" n["counter"], "gauge=" n["gauge"] }') $(metric nginx_up)" \
    "counter=3 gauge=5 1"

step "every scrape is a request too"
r0=$(metric nginx_http_requests_total)
for i in $(seq 10); do get > /dev/null; done
r1=$(metric nginx_http_requests_total)
echo "nginx_http_requests_total went up by $((r1 - r0)) for 10 requests"
expect "the exporter's GET /stub_status is counted with the others" "$((r1 - r0))" "11"

step "a reload keeps the counters, a restart starts them from zero"
before=$(metric nginx_http_requests_total)
k exec edge -c nginx -- nginx -c /etc/nginx/conf/edge.conf -s reload 2> /dev/null
until_ok 30 eval '[[ $(ctl /1/control/processes | grep -o "\"exiting\":true" | wc -l) == 0 ]]'
after=$(metric nginx_http_requests_total)
echo "after nginx -s reload: $( (( after > before )) && echo "higher than before" || echo "not higher")"
k exec edge -c nginx -- nginx -c /etc/nginx/conf/edge.conf -s stop 2> /dev/null || true
until_ok 90 eval '[[ $(k get pod edge -o jsonpath="{.status.containerStatuses[?(@.name==\"nginx\")].restartCount}") == 1 && $(metric nginx_up) == 1 ]]'
restarted=$(metric nginx_http_requests_total)
echo "after the nginx container restarted: $restarted (the two scrapes since the restart)"
expect "the counters live in shared memory the master maps once; a new master starts at 0" \
    "$( (( after > before )) && echo kept) $restarted" "kept 2"

step "JSON lines on stdout, and the runtime's 16 KiB records"
echo "containerd on $( [[ -n "$node" ]] && echo "the node"): $(docker exec "$node" containerd config dump 2> /dev/null | grep -o 'max_container_log_line_size = [0-9]*')"
get -H 'X-Request-ID: short-line' > /dev/null
get -H 'X-Request-ID: long-line' -A "$(head -c 20000 /dev/zero | tr '\0' a)" > /dev/null
sleep 1
echo "records of the short line: $(rec short-line | tr '\n' ';')"
echo "records of the long line: $(rec long-line | tr '\n' ';')"
echo "kubectl logs, the long line: $(k logs edge -c nginx | grep -a long-line | wc -l) line, $(k logs edge -c nginx | grep -a long-line | wc -c) bytes, valid JSON: $(k logs edge -c nginx | grep -a long-line | python3 -c 'import json, sys; json.load(sys.stdin); print("yes")' 2> /dev/null || echo no)"
expect "a line over 16384 bytes is stored as a partial record plus the rest; kubectl logs joins them" \
    "$(rec long-line | awk '{ print $2 }' | tr '\n' ' ')$(k logs edge -c nginx | grep -a long-line | wc -l)" "P F 1"

step "a request id across two hops"
get > /dev/null
id_edge=$(field edge request_id)
id_app=$(field app request_id)
echo "edge made $( [[ "$id_edge" =~ ^[0-9a-f]{32}$ ]] && echo "a 32-hex-digit id"), the app logged $( [[ "$id_app" == "$id_edge" ]] && echo "the same one" || echo "another one")"
get -H 'X-Request-ID: from-client-42' > /dev/null
echo "with X-Request-ID from the client: edge $(field edge request_id), app $(field app request_id)"
expect "the edge's id reaches the app; an id from the client is kept" \
    "$( [[ "$id_app" == "$id_edge" && "$id_edge" =~ ^[0-9a-f]{32}$ ]] && echo same) $(field edge request_id) $(field app request_id)" \
    "same from-client-42 from-client-42"

step "a traceparent passes through untouched"
tp=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
get -H "traceparent: $tp" > /dev/null
echo "client sent: $tp"
echo "edge logged: $(field edge traceparent)"
echo "app got:     $(field app traceparent)"
expect "without a tracing module nginx forwards the header as it came; no span for nginx" \
    "$(field app traceparent)" "$tp"

step "with nginx-otel: a span for nginx, and nginx as the app's parent"
conf traced-conf conf/traced.conf
conf collector-conf conf/collector.yaml
apply k8s/traced.yaml
ready app=collector
ready app=traced
kx client curl -s --max-time 10 -o /dev/null -H "traceparent: $tp" "http://$(addr traced)/"
tid=${tp:3:32} psid=${tp:36:16}
sid=$(field traced span_id)
echo "traced logged: trace_id $(field traced trace_id), parent_id $(field traced parent_id), span_id $( [[ "$sid" =~ ^[0-9a-f]{16}$ ]] && echo "<16 hex digits>")"
echo "app got:       $(field app traceparent | sed "s/$sid/<span_id of traced>/")"
until_ok 30 eval "k logs collector | grep -q 'Trace ID *: $tid'"
echo "the collector, $(k logs collector | grep -m1 -o 'service.name: Str([a-z]*)'):"
k logs collector | awk -v t="$tid" '$0 ~ "Trace ID *: " t { f = 1 } f && /^Span #|^ResourceSpans/ && n++ { exit }
    f && /Trace ID|Parent ID|^ *ID |Name|Kind|-> http\.(method|route|status_code)/ { print }' \
    | sed -E "s/$sid/<span_id of traced>/; s/^ +/    /"
expect "the trace id is kept, the client's span becomes nginx's parent, nginx's span the app's" \
    "$(field traced trace_id) $(field traced parent_id) $(field app traceparent | sed "s/$sid/SID/")" \
    "$tid $psid 00-$tid-SID-01"

step "with nginx-otel and no traceparent: nginx starts the trace"
kx client curl -s --max-time 10 -o /dev/null "http://$(addr traced)/"
t2=$(field traced trace_id) s2=$(field traced span_id)
echo "traced logged: trace_id $( [[ "$t2" =~ ^[0-9a-f]{32}$ && "$t2" != "$tid" ]] && echo "<new, 32 hex digits>"), parent_id \"$(field traced parent_id)\""
echo "app got:       $(field app traceparent | sed "s/$t2/<trace_id of traced>/; s/$s2/<span_id of traced>/")"
expect "a request without a context gets a new trace id; the app is its first child" \
    "$(field traced parent_id)|$(field app traceparent)" "|00-$t2-$s2-01"

step "after a reload, the old worker stays until its download ends"
kx client sh -c "curl -s -o /dev/null http://$(addr edge)/slow > /dev/null 2>&1 &"
until_ok 10 eval "k logs app -c nginx | grep -q . && ctl /1/control/processes | grep -q worker"
sleep 1
ctl /1/control/processes > out/run/p0.json
k exec edge -c nginx -- nginx -c /etc/nginx/conf/edge.conf -s reload 2> /dev/null
sleep 1
ctl /1/control/processes > out/run/p1.json
python3 -c 'import json; p = json.load(open("out/run/p1.json")); print("processes after the reload:", ", ".join(sorted("%s exiting=%s" % (x["name"], str(x["exiting"]).lower()) for x in p)))'
until_ok 60 eval '[[ $(ctl /1/control/processes | grep -o "\"exiting\":true" | wc -l) == 0 ]]'
echo "once the download finished: $(ctl /1/control/processes | python3 -c 'import json, sys; p = json.load(sys.stdin); print(len(p), "worker,", sum(x["exiting"] for x in p), "exiting")')"
expect "GET /1/control/processes shows the old worker as exiting while it still serves" \
    "$(grep -o '"exiting":true' out/run/p1.json | wc -l) $(grep -o '"exiting":false' out/run/p1.json | wc -l)" "1 1"
