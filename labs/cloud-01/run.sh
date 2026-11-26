# cloud-01: nginx in a container: how many workers auto starts, what each stop signal does to
# a request in flight, why a preStop sleep matters, and what a non-root read-only pod needs.
# Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

conf lab-conf conf/nginx.conf conf/tuned.conf conf/wst.conf
client

# workers POD: number of worker processes in the pod
workers() { kx "$1" ps -eo args= | grep -c '^nginx: worker process' || true; }

# big POD: put a 1 MB file at /srv/big/f.bin, served at 200 KB/s (5 s)
big() { kx "$1" sh -c 'head -c 1048576 /dev/zero > /srv/big/f.bin'; }

# podip POD
podip() { k get pod "$1" -o jsonpath='{.status.podIP}'; }

# download NAME POD: start fetching /big/f.bin from POD in the background
download() {
    kx client curl -s -o /dev/null -w '%{http_code} %{size_download} %{time_total}\n' \
        --max-time 30 "http://$(podip "$2")/big/f.bin" > "out/run/$1.txt" || true
}

# result NAME: "complete" or "cut" for a finished download
result() { awk '{ print ($2 == 1048576 ? "complete" : "cut") }' "out/run/$1.txt"; }

# nginx log lines without timestamps and pids
norm() { sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /; s/(received from|process) [0-9]+/\1 N/'; }

apply k8s/cpu.yaml
ready app=cpu; ready app=pinned; ready app=tuned
ncpu=$(kx cpu getconf _NPROCESSORS_ONLN)

step "worker_processes auto under a CPU limit"
# cgroup v1 keeps quota and period in two files, v2 in cpu.max
quota=$(kx cpu sh -c 'cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo "$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us) $(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"')
echo "CFS quota and period (us): $quota"
echo "CPUs online in the pod: NCPU"
echo "worker processes: $(workers cpu | sed "s/^$ncpu\$/NCPU/")"
expect "a limit of 1 CPU still gives one worker per CPU of the node" \
    "$quota $(workers cpu)" "100000 100000 $ncpu"

step "worker_processes auto under taskset"
echo "Cpus_allowed_list of PID 1: $(kx pinned grep Cpus_allowed_list /proc/1/status | awk '{ print $2 }')"
echo "worker processes: $(workers pinned | sed "s/^$ncpu\$/NCPU/")"
expect "the affinity mask is not counted either" \
    "$(kx pinned grep Cpus_allowed_list /proc/1/status | awk '{ print $2 }') $(workers pinned)" "0 $ncpu"

step "worker_processes from the downward API"
kx tuned ps -o args= -p 1
echo "worker processes: $(workers tuned)"
expect "limits.cpu 2 passed with -g gives two workers" "$(workers tuned)" "2"
k delete pod cpu pinned tuned --wait=false > /dev/null

apply k8s/stop.yaml
ready app=stop
for p in quit term grace wst; do big $p; done

step "deleting a pod sends the image's STOPSIGNAL"
k logs -f quit > out/run/quit.log 2>&1 & logs=$!
download quit quit & d=$!
sleep 1
k delete pod quit --wait=false > /dev/null
wait $d; wait $logs || true
norm < out/run/quit.log | grep -E 'signal 3|gracefully|"GET /big' | awk '!seen[$0]++'
echo "download: $(result quit)"
expect "SIGQUIT lets the download finish" "$(result quit)" "complete"

step "SIGTERM instead"
k logs -f term > out/run/term.log 2>&1 & logs=$!
download term term & d=$!
sleep 1
kx term sh -c 'kill -TERM 1'
wait $d; wait $logs || true
norm < out/run/term.log | grep -E 'signal 15|exiting|"GET /big' | awk '!seen[$0]++'
echo "download: $(result term)"
gate=$(kubectl get --raw /metrics | grep -o 'kubernetes_feature_enabled{name="ContainerStopSignals".*')
echo "$gate"
expect "SIGTERM cuts it; a per-pod stop signal is an alpha feature, off by default" \
    "$(result term) $(awk '{ print $2 }' <<< "$gate")" "cut 0"

step "the grace period and worker_shutdown_timeout"
k logs -f grace > out/run/grace.log 2>&1 & l1=$!
k logs -f wst > out/run/wst.log 2>&1 & l2=$!
download grace grace & d1=$!
download wst wst & d2=$!
sleep 1
k delete pod grace wst --wait=false > /dev/null
t0=$(date +%s.%N)
wait $d2; t2=$(date +%s.%N)
wait $d1; t1=$(date +%s.%N)
# seconds from the deletion to the end of each download, rounded to whole seconds
s1=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.0f", b - a }')
s2=$(awk -v a="$t0" -v b="$t2" 'BEGIN { printf "%.0f", b - a }')
echo "terminationGracePeriodSeconds 2: download $(result grace) about $s1 s after the deletion"
echo "worker_shutdown_timeout 1s: download $(result wst) about $s2 s after the deletion"
wait $l1 $l2 || true
# the access log line of the download, if any, with the byte count reduced to full / partial
for n in grace wst; do
    echo "access log of $n: $(grep -a '"GET /big' "out/run/$n.log" \
        | awk '{ print $(NF - 1), ($NF == 1048576 ? "full" : "partial") }' | grep . || echo none)"
done
expect "SIGKILL after the grace period cuts the download unlogged; worker_shutdown_timeout cuts it first and logs it" \
    "$(result grace) $s1 $(grep -ac '"GET /big' out/run/grace.log) $(result wst) $s2 $(grep -a '"GET /big' out/run/wst.log | awk '{ print $(NF - 1) }')" \
    "cut 2 0 cut 1 200"
k delete pod term --wait=false > /dev/null

apply k8s/prestop.yaml
ready app=ep
big bare; big sleepy
ipb=$(podip bare); ips=$(podip sleepy)

step "a terminating pod with and without preStop"
download bare bare & d1=$!
download sleepy sleepy & d2=$!
sleep 1
k delete pod bare sleepy --wait=false > /dev/null
sleep 1.5
nb=$(kx client curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$ipb/" || true)
ns=$(kx client curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$ips/" || true)
echo "new request to bare (no preStop): $nb"
echo "new request to sleepy (preStop sleep 5): $ns"
k get endpointslices -l kubernetes.io/service-name=ep -o json | python3 -c '
import json, sys
for s in json.load(sys.stdin)["items"]:
    for e in sorted(s.get("endpoints") or [], key=lambda e: e["targetRef"]["name"]):
        c = e["conditions"]
        print("endpoint %s: ready=%s serving=%s terminating=%s" % (e["targetRef"]["name"],
              str(c.get("ready")).lower(), str(c.get("serving")).lower(), str(c.get("terminating")).lower()))'
wait $d1 $d2
echo "downloads in flight: bare $(result bare), sleepy $(result sleepy)"
expect "without preStop the pod refuses new connections at once; with it, it still answers" \
    "$nb $ns $(result bare) $(result sleepy)" "000 200 complete complete"

apply k8s/roll.yaml
k rollout status deploy/roll --timeout=180s > /dev/null

# load NAME SECONDS: two clients, each sending one request to the Service's ClusterIP every
# 20 ms for SECONDS; status code and curl exit code (7: connection refused) go to NAME
load() {
    kx client sh -c 'end=$(( $(date +%s) + '"$2"' ))
        one() { while [ "$(date +%s)" -lt $end ]; do
            curl -s -o /dev/null -w "%{http_code} %{exitcode}\n" --max-time 2 http://'"$(k get svc roll -o jsonpath='{.spec.clusterIP}')"'/
            sleep 0.02; done; }
        one & one & wait' > "out/run/$1.txt" || true
}
# refused NAME: requests whose connection was refused
refused() { grep -c '^000 7$' "out/run/$1.txt" || true; }

step "a rolling restart under load"
load plain 20 & d=$!
sleep 2
k rollout restart deploy/roll > /dev/null
k rollout status deploy/roll --timeout=180s > /dev/null
wait $d
echo "requests: $(wc -l < out/run/plain.txt | awk '{ print ($1 > 400 ? "more than 400" : $1) }'), connection refused: $(refused plain | awk '{ print ($1 > 0 ? "some" : "none") }')"
k patch deploy/roll --patch-file k8s/roll-prestop.yaml > /dev/null
k rollout status deploy/roll --timeout=180s > /dev/null
# the pods replaced by the patch had no preStop hook: wait until they are gone
for i in $(seq 120); do (( $(pods app=roll | wc -l) == 2 )) && break; sleep 0.5; done
sleep 2
load prestop 30 & d=$!
sleep 2
k rollout restart deploy/roll > /dev/null
k rollout status deploy/roll --timeout=180s > /dev/null
wait $d
echo "with preStop sleep 5: requests: $(wc -l < out/run/prestop.txt | awk '{ print ($1 > 400 ? "more than 400" : $1) }'), connection refused: $(refused prestop)"
expect "without preStop the restart sends requests to closed sockets, with it none" \
    "$(refused plain | awk '{ print ($1 > 0 ? "some" : "none") }') $(refused prestop)" "some 0"
k delete deploy roll --wait=false > /dev/null

apply k8s/ro.yaml
k wait --for=jsonpath='{.status.phase}'=Failed pod/ro1 pod/ro2 --timeout=120s > /dev/null
k wait --for=condition=Ready pod/ro3 --timeout=120s > /dev/null

step "non-root on a read-only root filesystem"
for p in ro1 ro2; do
    echo "$p: $(k get pod $p -o jsonpath='{.status.phase}')"
    k logs $p 2>&1 | norm | grep -E '^\[(emerg|alert)\]' | sed 's/^/  /'
done
echo "ro3: $(k get pod ro3 -o jsonpath='{.status.phase}')"
kx ro3 ps -eo user=,args= | awk '$2 == "nginx:" { n[$1 " " $3 " " $4]++ } END { for (p in n) print "  " p ": " n[p] }' \
    | sort | sed "s/: $ncpu\$/: NCPU/"
echo "  ip_unprivileged_port_start: $(kx ro3 cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"
echo "  request on port 80: $(kx client curl -s -o /dev/null -w '%{http_code}' "http://$(podip ro3)/")"
expect "uid 101 needs writable temp paths and pid directory, nothing else; port 80 works" \
    "$(k get pod ro1 ro2 ro3 -o jsonpath='{range .items[*]}{.status.phase} {end}')$(kx client curl -s -o /dev/null -w '%{http_code}' "http://$(podip ro3)/")" \
    "Failed Failed Running 200"
