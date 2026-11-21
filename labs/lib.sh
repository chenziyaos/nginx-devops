# Shared helpers for labs/<id>/run.sh. Source it first:  . "$(dirname "$0")/../lib.sh"
#
# Every lab runs a private nginx with prefix = the lab directory, so relative paths in
# conf/nginx.conf (logs/, html/, *_temp/) resolve inside the lab. Do not set "pid" in
# the lab config; start() passes it with -g.
set -Eeuo pipefail

LAB=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)
ROOT=$(cd "$LAB/../.." && pwd)
NGINX=${NGINX:-$ROOT/.nginx/sbin/nginx}
CONF=${CONF:-conf/nginx.conf}
cd "$LAB"

[[ -x "$NGINX" ]] || { echo "nginx not found at $NGINX; run tools/build.sh first" >&2; exit 2; }

# Every run starts from a clean state: no logs, temp dirs or cache from the previous run.
rm -rf logs out/run ./*_temp
mkdir -p logs out/run

ngx() { "$NGINX" -p "$LAB/" -e logs/error.log -g "pid logs/nginx.pid;" "$@"; }

# step "title": a section marker; chapters quote the output between markers.
step() { printf '\n## %s\n' "$*"; }

master_pid() { cat logs/nginx.pid 2>/dev/null || true; }

# start [conf]: start nginx with the given config (default conf/nginx.conf), wait for the pid file.
# nginx is started through a symlink <dir>/.active.conf -> <conf>, because on HUP the master
# re-reads the file it was started with; reload <other.conf> re-points the symlink.
start() {
    local conf=${1:-$CONF}
    : > logs/error.log
    : > logs/access.log
    ln -sfn "$(basename "$conf")" "$(dirname "$conf")/.active.conf"
    ngx -c "$(dirname "$conf")/.active.conf"
    local i
    for i in $(seq 50); do
        [[ -s logs/nginx.pid ]] && kill -0 "$(master_pid)" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "nginx did not start" >&2
    cat logs/error.log >&2
    return 1
}

# stop: fast shutdown, wait until the master has exited. Safe to call twice.
stop() {
    local pid
    pid=$(master_pid)
    [[ -n "$pid" ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in $(seq 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    rm -f logs/nginx.pid
}
trap stop EXIT

# reload [conf]: switch the running master to conf (default: keep the current one), send HUP
# and wait until the old workers are gone. A config that fails to load leaves the old workers
# running, so this times out; to show a rejected reload use reload_nowait and check error.log.
reload() {
    local old
    old=$(worker_pids)
    reload_nowait "$@"
    local i w
    for i in $(seq 100); do
        sleep 0.1
        for w in $old; do kill -0 "$w" 2>/dev/null && continue 2; done
        return 0
    done
    echo "old workers still running after reload" >&2
    return 1
}

# reload_nowait [conf]: re-point the active config (same directory as the started one) and send HUP.
reload_nowait() {
    local active
    active=$(readlink -n "$(dirname "${1:-$CONF}")/.active.conf" 2>/dev/null || true)
    [[ -n "$active" ]] || { echo "reload: no active config in $(dirname "${1:-$CONF}")/" >&2; return 1; }
    if [[ -n "${1:-}" ]]; then
        ln -sfn "$(basename "$1")" "$(dirname "$1")/.active.conf"
    fi
    ngx -c "$(dirname "${1:-$CONF}")/.active.conf" -s reload
}

# worker_pids: pids of the current worker processes (children of the master).
worker_pids() { pgrep -P "$(master_pid)" 2>/dev/null | sort -n | tr '\n' ' ' || true; }

# code URL [curl args...]: print the HTTP status code only.
code() { local u=$1; shift; curl -s -o /dev/null -w '%{http_code}\n' "$@" "$u"; }

# get URL [curl args...]: print the body.
get() { local u=$1; shift; curl -s "$@" "$u"; echo; }

# hdrs URL REGEX [curl args...]: status line plus the response headers matching REGEX
# (case-insensitive), CR stripped, Date always dropped.
hdrs() {
    local u=$1 re=$2; shift 2
    curl -s -o /dev/null -D - "$@" "$u" | tr -d '\r' \
        | awk -v re="$re" 'NR == 1 { print; next } tolower($0) ~ "^date:" { next } tolower($0) ~ tolower(re) { print }'
}

# errlog REGEX: matching error.log lines without the timestamp and pid#tid prefix.
errlog() {
    grep -aE "$1" logs/error.log | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /' || true
}

# accesslog: access.log content as is (labs choose a log_format without timestamps).
accesslog() { cat logs/access.log; }

# t: nginx -t for the given config, output normalized (the prefix path is replaced by $LAB).
t() {
    local conf=${1:-$CONF}
    ngx -t -c "$conf" 2>&1 | sed -e "s#$LAB/#\$LAB/#g" -E -e 's/^nginx: //' \
        -e 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /' || true
}

# fire N URL [curl args...]: send N requests at the same moment (N curl processes) and
# print how many got each status, e.g. "6x 200" / "2x 503". Sorted, so the output does
# not depend on arrival order. The slowest response time is kept for slowest_at_least.
fire() {
    local n=$1 u=$2 i
    shift 2
    for i in $(seq "$n"); do
        curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$@" "$u" &
    done > out/run/fire.txt
    wait
    sort out/run/fire.txt | awk '{ print $1 }' | uniq -c | awk '{ print $1 "x " $2 }'
}

# slowest_at_least S: after fire, print whether the slowest response took at least S seconds.
# Use it for "the queue made someone wait": exact times jitter, a lower bound does not.
slowest_at_least() {
    sort -k2,2n out/run/fire.txt | tail -1 \
        | awk -v s="$1" '{ print "slowest response >= " s " s: " ($2 + 0 >= s ? "yes" : "no") }'
}

# all_below S: after fire, print whether every response took less than S seconds.
all_below() {
    sort -k2,2n out/run/fire.txt | tail -1 \
        | awk -v s="$1" '{ print "every response < " s " s: " ($2 + 0 < s ? "yes" : "no") }'
}

# seq_codes N URL [curl args...]: send N requests one after another, print the status codes
# on one line, e.g. "200 503 503".
seq_codes() {
    local n=$1 u=$2 i out=()
    shift 2
    for i in $(seq "$n"); do
        out+=("$(curl -s -o /dev/null -w '%{http_code}' "$@" "$u")")
    done
    echo "${out[*]}"
}

# expect "claim" ACTUAL WANTED: state what the chapter claims, then check it.
# Prints "ok - claim" or "NOT OK - claim: got <actual>, want <wanted>";
# tools/verify_labs.sh fails a lab whose output contains "NOT OK".
# Write the WANTED value from the source code before running the lab.
expect() {
    if [[ "$2" == "$3" ]]; then
        echo "ok - $1"
    else
        echo "NOT OK - $1: got [$2], want [$3]"
    fi
}

# expect_match "claim" ACTUAL REGEX: like expect, but WANTED is an extended regex.
expect_match() {
    if [[ "$2" =~ $3 ]]; then
        echo "ok - $1"
    else
        echo "NOT OK - $1: got [$2], want /$3/"
    fi
}

# count_status STATUS: after fire, how many responses had that status.
count_status() { awk -v s="$1" '$1 == s' out/run/fire.txt | wc -l | tr -d ' '; }

# count_log REGEX: how many access.log lines match.
count_log() { grep -cE "$1" logs/access.log || true; }
