# cloud-04: delivering nginx config through a ConfigMap: how the files change in the pod,
# reloading through the control API from a sidecar, and what `nginx -s reload` and
# PATCH /1/control/config report for three kinds of bad config.
# Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

# nx POD CMD...: run CMD in the nginx container of POD
nx() { local pod=$1; shift; k exec "$pod" -c nginx -- "$@"; }
# cm FILE: make FILE the nginx.conf of the ConfigMap web-conf
cm() {
    k create configmap web-conf --from-file=nginx.conf="$1" --dry-run=client -o yaml \
        | k apply -f - > /dev/null
}
# marker POD FILE: the "# config: NAME" of FILE in POD's nginx container
marker() { nx "$1" sed -n 's/^# config: //p' "$2"; }
LIVE=/etc/nginx/live/nginx.conf
# running POD: the "# config: NAME" of the config nginx in POD runs, from the control API
running() {
    nx "$1" curl -s --unix-socket /run/ctl/nginx.sock http://localhost/1/control/config \
        | grep -o '# config: [a-z0-9-]*' | sed 's/# config: //'
}
# patch POD: PATCH /1/control/config in POD; prints the status code
patch() {
    nx "$1" curl -s --unix-socket /run/ctl/nginx.sock -X PATCH -o /dev/null \
        -w '%{http_code}' http://localhost/1/control/config
}
ans() { kx client curl -s --max-time 5 "http://$(k get pod "$1" -o jsonpath='{.status.podIP}')/"; }
# sync_now: a changed annotation makes kubelet sync the pods, and with them their volumes
sync_now() { k annotate pod plain web lab/sync="$(date +%s%N)" --overwrite > /dev/null; }
until_ok() {
    local end=$(( $(date +%s) + $1 ))
    shift
    until "$@" > /dev/null 2>&1; do
        (( $(date +%s) < end )) || { echo "timed out: $*" >&2; return 1; }
        sleep 0.5
    done
}
reloads() { k logs web -c reloader | grep -c '^reload:' || true; }
# lastreload: the sidecar's last line, without the timestamps and pids inside the JSON
lastreload() {
    k logs web -c reloader | tail -1 | sed -E 's/[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9:]{8} (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /g'
}
# timestamps and pids out of error log lines
plainlog() { sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /'; }
# signal POD: nginx -s reload in POD; prints "exit N" and what it wrote
signal() {
    local out rc=0
    out=$(nx "$1" nginx -c "$LIVE" -s reload 2>&1) || rc=$?
    echo "exit $rc"
    # the signaller writes each line to stderr and to the error log (stderr too): keep one
    grep -v '^command terminated' <<< "$out" | plainlog | sed 's/^nginx: //' | awk '!seen[$0]++' \
        | sed 's/^/  /' || true
}
# bad NAME: deliver conf/NAME.conf to both pods and let the sidecar react
bad() {
    local n
    n=$(reloads)
    cm "conf/$1.conf"
    sync_now
    until_ok 30 eval "[[ \$(marker plain $LIVE) == $1 && \$(marker web $LIVE) == $1 ]]"
    until_ok 30 eval "[[ \$(reloads) -gt $n ]]"
}

cm conf/v1.conf
conf reloader conf/reload.sh
apply k8s/pods.yaml
client
ready app=web

step "a ConfigMap mounted as a directory"
nx plain sh -c 'cd /etc/nginx/live && for f in ..data nginx.conf; do echo "$f -> $(readlink "$f")"; done' \
    | sed -E 's/[0-9]{4}(_[0-9]{2}){5}\.[0-9]+/<timestamp>/'
echo "files nginx loaded, from GET /1/control/config: $(nx plain curl -s --unix-socket /run/ctl/nginx.sock http://localhost/1/control/config | grep -o '"name":"[^"]*"' | tr '\n' ' ')"
echo "answers: plain $(ans plain), web $(ans web)"
expect "nginx runs the file the ConfigMap's ..data link points to" \
    "$(ans plain) $(ans web) $(running plain)" "v1 v1 v1"

step "an update reaches the directory mount, not the subPath mount"
cm conf/v2.conf
t0=$(date +%s)
until_ok 150 eval "[[ \$(marker plain $LIVE) == v2 ]]"
secs=$(( $(date +%s) - t0 ))
echo "$secs" > out/run/delay.txt
echo "directory mount of plain shows v2 within 120 s: $( (( secs <= 120 )) && echo yes || echo no)"
echo "subPath mount of plain: $(marker plain /etc/nginx/subpath.conf)"
expect "kubelet updates the directory at its next sync; the subPath file stays" \
    "$(marker plain $LIVE) $(marker plain /etc/nginx/subpath.conf) $( (( secs <= 120 )) && echo yes)" "v2 v1 yes"

step "nginx keeps running the old config"
echo "plain: file $(marker plain $LIVE), running $(running plain), answers $(ans plain)"
before="$(running plain) $(ans plain)"
code=$(patch plain)
echo "PATCH /1/control/config: $code"
echo "plain: file $(marker plain $LIVE), running $(running plain), answers $(ans plain)"
expect "the new file is used only after a reload" "$before $code $(running plain) $(ans plain)" "v1 v1 200 v2 v2"

step "a sidecar that reloads through the control API"
until_ok 150 eval "[[ \$(marker web $LIVE) == v2 ]]"
until_ok 15 eval "[[ \$(ans web) == v2 ]]"
k logs web -c reloader | sed 's/^/reloader: /'
echo "web answers: $(ans web)"
expect "the sidecar's PATCH loads v2 into web" "$(k logs web -c reloader | tail -1 | cut -d' ' -f2) $(ans web)" "200 v2"

step "a misspelled directive"
bad bad-directive
echo "plain, nginx -s reload: $(signal plain)"
echo "web, $(lastreload)"
echo "answers: plain $(ans plain), web $(ans web)"
expect "both ways refuse it; the old config keeps serving" \
    "$(signal plain | head -1) $(k logs web -c reloader | tail -1 | cut -d' ' -f2) $(ans plain) $(ans web)" \
    "exit 1 422 v2 v2"

step "a certificate that is not there"
bad bad-cert
echo "plain, nginx -s reload: $(signal plain)"
echo "web, $(lastreload)"
echo "answers: plain $(ans plain), web $(ans web)"
expect "the signaller loads certificates too, so both ways refuse it" \
    "$(signal plain | head -1) $(k logs web -c reloader | tail -1 | cut -d' ' -f2) $(ans plain) $(ans web)" \
    "exit 1 422 v2 v2"

step "a log directory that does not exist"
bad bad-log
s=$(signal plain)
echo "plain, nginx -s reload: $s"
sleep 1
echo "plain, nginx's own log:"
k logs plain -c nginx | plainlog | grep -a 'ngnix' | sort -u | sed 's/^/  /'
echo "web, $(lastreload)"
echo "answers: plain $(ans plain), web $(ans web)"
expect "nginx -s reload exits 0 while the reload fails; PATCH reports it" \
    "$(head -1 <<< "$s") $(k logs plain -c nginx | grep -ac 'open() "/var/log/ngnix/access.log" failed' | awk '{ print ($1 > 0) }') $(k logs web -c reloader | tail -1 | cut -d' ' -f2) $(ans plain) $(ans web)" \
    "exit 0 1 422 v2 v2"

step "a restart after a failed reload"
echo "plain: file $(marker plain $LIVE), running $(running plain)"
nx plain nginx -c "$LIVE" -s stop > /dev/null 2>&1 || true
until_ok 90 eval "[[ \$(k get pod plain -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}') == 1 ]]"
echo "plain after nginx -s stop: last exit code $(k get pod plain -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}')"
k logs plain -c nginx --previous > out/run/previous.log 2>&1 || true
plainlog < out/run/previous.log | sed 's/^nginx: //' | awk '!seen[$0]++' | sed 's/^/  /'
echo "answers: plain $(ans plain 2> /dev/null || echo none), web $(ans web)"
expect "nginx starts from the bad file and fails; web, not restarted, still serves v2" \
    "$(grep -ac '^nginx: \[emerg\] open() "/var/log/ngnix/access.log" failed' out/run/previous.log) $(ans web)" "1 v2"

step "a good config after the failures"
cm conf/v3.conf
sync_now
until_ok 30 eval "[[ \$(ans web) == v3 ]]"
echo "web, $(k logs web -c reloader | tail -1 | cut -d' ' -f1-2)"
until_ok 120 eval "[[ \$(ans plain) == v3 ]]"
echo "answers: plain $(ans plain), web $(ans web)"
expect "the sidecar loads v3; plain starts again once its file is good" \
    "$(k logs web -c reloader | tail -1 | cut -d' ' -f2) $(ans web) $(ans plain)" "200 v3 v3"
