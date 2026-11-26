# cloud-02: reaching pods through a Service: a ClusterIP as one server, a headless Service
# resolved at startup or at run time, scaling out and in, and the resolver's search rules.
# Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

conf lab-conf conf/backend.conf conf/front.conf
apply k8s/backend.yaml
k rollout status deploy/backend --timeout=180s > /dev/null
apply k8s/front.yaml
client
ready app=front
F=$(k get pod front -o jsonpath='{.status.podIP}')

# hits PORT N: N sequential requests to the front on PORT; prints how many each pod
# answered, largest first; a request that fails adds "+N failed", so it cannot go unnoticed
hits() {
    kx client sh -c "for i in \$(seq $2); do curl -s --max-time 5 http://$F:$1/ || echo FAILED; done; true" \
        | sort | uniq -c | awk '$2 == "FAILED" { f = $1; next } { print $1 } END { if (f) print "+" f " failed" }' \
        | sort -rn | tr '\n' ' ' | sed 's/ $//'
}

step "a ClusterIP Service as one upstream server"
c=$(hits 8081 300)
echo "upstream block, keepalive by default: $c"
expect "every request rides the same kept-alive connection to one pod" "$c" "300"

step "a ClusterIP Service in proxy_pass"
c=$(hits 8082 300)
echo "pods that answered: $(wc -w <<< "$c" | tr -d ' ')"
echo "each pod answered at least 50 of 300: $(awk '{ for (i = 1; i <= NF; i++) if ($i < 50) { print "no"; exit } print "yes" }' <<< "$c")"
expect "a new connection per request lets kube-proxy spread them" "$(wc -w <<< "$c" | tr -d ' ')" "3"

step "a headless Service with resolve"
c=$(hits 8083 300)
echo "upstream with zone and resolve: $c"
expect "nginx sees every pod and round robin is exact" "$c" "100 100 100"

step "scaling out to 5 pods"
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' \
    | grep -E '^\s*(ttl|cache) [0-9]+' | sed -E 's/^\s+/CoreDNS Corefile: /'
k scale deploy/backend --replicas=5 > /dev/null
k rollout status deploy/backend --timeout=180s > /dev/null
t0=$(date +%s)
seen=0
while (( $(date +%s) - t0 < 40 )); do
    seen=$(hits 8083 10 | wc -w | tr -d ' ')
    (( seen == 5 )) && break
    sleep 0.5
done
waited=$(( $(date +%s) - t0 ))
echo "resolve: all 5 pods answered within 35 s of becoming ready: $( (( seen == 5 && waited <= 35 )) && echo yes || echo no)"
echo "resolved at startup: pods answering: $(hits 8084 30 | wc -w | tr -d ' ')"
echo "ClusterIP with keepalive: pods answering: $(hits 8081 30 | wc -w | tr -d ' ')"
expect "run-time resolution picks up the new pods; startup resolution and the kept connection do not" \
    "$seen $(hits 8084 30 | wc -w | tr -d ' ') $(hits 8081 30 | wc -w | tr -d ' ')" "5 3 1"

step "scaling in to 2 pods under load"
kx client sh -c "end=\$(( \$(date +%s) + 20 ))
    one() { while [ \"\$(date +%s)\" -lt \$end ]; do
        curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://$F:8083/; sleep 0.02; done; }
    one & one & wait" > out/run/down.txt & d=$!
sleep 3
k scale deploy/backend --replicas=2 > /dev/null
wait $d
k logs front > out/run/front.log
retried=$(grep -c '^8083 200 .*, ' out/run/front.log || true)
echo "client: $(grep -c '^200$' out/run/down.txt | awk '{ print ($1 > 400 ? "more than 400" : $1) }') answered 200, $(grep -vc '^200$' out/run/down.txt || true) failed"
echo "requests that nginx retried on another pod: $( (( retried > 0 )) && echo some || echo none)"
# the distinct upstream errors in the front's error log, without addresses
grep -aE 'connect\(\) failed|timed out|temporarily disabled' out/run/front.log \
    | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: \*[0-9]+ /\1 /; s/, client: .*//' | sort -u
sleep 35
c=$(hits 8083 300)
echo "35 s later: $c"
expect "no client errors while pods go away; afterwards round robin over the 2 left" \
    "$(grep -vc '^200$' out/run/down.txt || true) $c" "0 150 150"

step "a short name with resolve"
echo "request: $(kx client curl -s -o /dev/null -w '%{http_code}' "http://$F:8085/")"
k logs front | grep -a 'could not be resolved' | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /' | awk '!seen[$0]++'
expect "the resolver does not apply search domains" \
    "$(kx client curl -s -o /dev/null -w '%{http_code}' "http://$F:8085/") $(k logs front | grep -ac 'backend-headless could not be resolved (3: Host not found)' | awk '{ print ($1 > 0) }')" \
    "502 1"
