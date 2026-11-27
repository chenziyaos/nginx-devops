# cloud-08: what changed between the 1.26 stable branch, the 1.30 stable branch and the
# 1.31 mainline, on the same config: directives that came from the commercial version,
# keepalive to backends, and stricter parsing of requests. Expected values come from the
# source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

until_ok() {
    local end=$(( $(date +%s) + $1 ))
    shift
    until "$@" > /dev/null 2>&1; do
        (( $(date +%s) < end )) || { echo "timed out: $*" >&2; return 1; }
        sleep 0.5
    done
}
PODS="v126 v130 v131"
addr() { k get pod "$1" -o jsonpath='{.status.podIP}'; }
# probe POD FILE: "accepted" if nginx -t accepts conf/FILE in POD, else its emerg without the path
probe() {
    local out
    if out=$(k exec "$1" -- nginx -t -c "/etc/nginx/lab/$2" 2>&1); then
        echo accepted
    else
        echo "$out" | sed -n 's/^nginx: \[emerg\] \(.*\) in \/etc\/nginx\/lab\/.*/\1/p' | head -1
    fi
}
# conns POD PORT: requests and distinct connections the backend on PORT saw
conns() {
    k exec "$1" -- cat "/tmp/backend-$2.log" | awk '{ n++; c[$1] } END { m = length(c); print n " requests, " m (m == 1 ? " connection" : " connections") }'
}
# raw POD REQUEST: the status line nginx sends for a raw request (printf format)
raw() {
    kx client bash -c "exec 3<>/dev/tcp/$(addr "$1")/80; printf '$2' >&3; head -1 <&3 | tr -d '\r'"
}

k create configmap lab-conf --from-file=conf/ --dry-run=client -o yaml | k apply -f - > /dev/null
apply k8s/pods.yaml
client
ready app=nginx
for p in $PODS; do until_ok 60 kx client curl -sf "http://$(addr $p)/ready"; done

step "three versions, one config"
for p in $PODS; do echo "$p: $(k exec $p -- nginx -v 2>&1 | sed 's/^nginx version: //')"; done
expect "the same config loads in all three" \
    "$(for p in $PODS; do k exec $p -- nginx -t -c /etc/nginx/lab/nginx.conf 2>&1 | grep -c 'test is successful'; done | tr '\n' ' ')" "1 1 1 "

step "directives that used to be commercial"
printf '%-24s %-34s %-34s %s\n' "" "1.26.3" "1.30.8" "1.31.10"
for f in probe-resolve probe-sticky probe-least-time; do
    printf '%-24s %-34s %-34s %s\n' "$(echo ${f#probe-} | tr - _)" "$(probe v126 $f.conf)" "$(probe v130 $f.conf)" "$(probe v131 $f.conf)"
done
expect "resolve (1.27.3) and sticky (1.29.6) are in 1.30, least_time (1.31.0) only in 1.31" \
    "$(for f in probe-resolve probe-sticky probe-least-time; do for p in $PODS; do [[ $(probe $p $f.conf) == accepted ]] && echo -n y || echo -n n; done; echo -n ' '; done)" \
    "nyy nyy nny "

step "keepalive to backends is on by default, for an upstream block"
for p in $PODS; do
    for i in $(seq 10); do kx client curl -s -o /dev/null "http://$(addr $p)/explicit"; kx client curl -s -o /dev/null "http://$(addr $p)/implicit"; done
    echo "$p: upstream block: $(conns $p 8081); address in proxy_pass: $(conns $p 8082)"
done
expect "1.29.7 made keepalive the default for upstream blocks only" \
    "$(for p in $PODS; do conns $p 8081 | awk '{ printf "%s/", $3 }'; conns $p 8082 | awk '{ printf "%s ", $3 }'; done)" \
    "10/10 1/10 1/10 "

step "a chunk size line ended by a bare LF"
for p in $PODS; do
    echo "$p: $(raw $p 'POST /explicit HTTP/1.1\r\nHost: lab\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\nhello\r\n0\r\n\r\n')"
done
expect "rejected since 1.29.4, so in 1.30 as well" \
    "$(for p in $PODS; do raw $p 'POST /explicit HTTP/1.1\r\nHost: lab\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\nhello\r\n0\r\n\r\n' | awk '{ printf "%s ", $2 }'; done)" \
    "200 400 400 "

step "a header line without a colon"
for p in $PODS; do
    echo "$p: $(raw $p 'GET /explicit HTTP/1.1\r\nHost: lab\r\nX-No-Colon\r\nConnection: close\r\n\r\n')"
done
expect "rejected since 1.31.9; the 1.30 branch still takes it as a header with an empty value" \
    "$(for p in $PODS; do raw $p 'GET /explicit HTTP/1.1\r\nHost: lab\r\nX-No-Colon\r\nConnection: close\r\n\r\n' | awk '{ printf "%s ", $2 }'; done)" \
    "200 200 400 "
