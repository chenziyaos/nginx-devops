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
start() {
    local conf=${1:-$CONF}
    : > logs/error.log
    : > logs/access.log
    ngx -c "$conf"
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

# reload [conf]: send HUP and wait until the old workers are gone.
reload() {
    local conf=${1:-$CONF} pid old
    pid=$(master_pid)
    old=$(worker_pids)
    ngx -c "$conf" -s reload
    local i w
    for i in $(seq 100); do
        sleep 0.1
        for w in $old; do kill -0 "$w" 2>/dev/null && continue 2; done
        return 0
    done
    echo "old workers still running after reload" >&2
    return 1
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
    grep -E "$1" logs/error.log | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /' || true
}

# accesslog: access.log content as is (labs choose a log_format without timestamps).
accesslog() { cat logs/access.log; }

# t: nginx -t for the given config, output normalized (the prefix path is replaced by $LAB).
t() {
    local conf=${1:-$CONF}
    ngx -t -c "$conf" 2>&1 | sed -e "s#$LAB/#\$LAB/#g" -E -e 's/^nginx: //' \
        -e 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /' || true
}
