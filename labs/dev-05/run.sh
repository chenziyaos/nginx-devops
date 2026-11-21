# dev-05: the master and worker loops and the event loop, seen through the debug log of one
# worker, lsof and the sizes printed by ev.c (linked against the build's objects by
# labs/ctest.sh). Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

# loop: the event loop lines of the debug log, without times, ports and addresses
loop() {
    grep -aE "$1" logs/error.log \
        | grep -aE 'worker cycle|kevent timer|kevent events|kevent: [0-9]+:|kevent set event|accept on|accept: |event timer (add|del)|wait request handler|keepalive handler|post event|posted event|pipelined request|close http connection|timer delta|client timed out|channel command|accept mutex' \
        | sed -E -e 's/^[0-9\/]+ [0-9:]+ \[[a-z]+\] [0-9]+#[0-9]+: //' -e 's/^\*[0-9]+ //' \
            -e 's/(event timer (add|del): [0-9]+: ([0-9]+:)?)[0-9]+$/\1/; s/: *$//' \
            -e 's/ ud:[0-9A-F]+//; s/ ff:[0-9A-F]+//' -e 's/timer delta: [0-9]+/timer delta/' \
            -e 's/127.0.0.1:[0-9]+ fd/127.0.0.1 fd/' -e 's/(post|posted|delete posted) event [0-9A-F]+/\1 event/' \
            -e 's/\(60: Operation timed out\)/(ETIMEDOUT)/'
}

worker() { pgrep -P "$(master_pid)" | head -1; }

step "worker startup"
start
sleep 0.3
w=$(worker)
grep -aE "^[0-9/]+ [0-9:]+ \[debug\] $w#[0-9]+: malloc: [0-9A-F]+:(126976|53248)$" logs/error.log \
    | sed -E 's/.*malloc: [0-9A-F]+:/malloc /'
loop "\] $w#" | sed -n '1,4p'
ctest ev.c
# ngx_event_process_init: connections, read events and write events, worker_connections
# (default 512) each; the listening socket and the channel are registered level-triggered
expect "connections and events are allocated up front: 512 x sizeof" \
    "$(ctest ev.c | sed -n 's/^x 512 connections: \([0-9]*\) and \([0-9]*\) bytes$/\1 \2/p')" \
    "$(grep -aE "\] $w#[0-9]+: malloc: [0-9A-F]+:(126976|53248)$" logs/error.log | sed -E 's/.*://' | sort -rnu | tr '\n' ' ' | sed 's/ $//')"

step "one request through the event loop"
: > logs/error.log
curl -s -o /dev/null -H 'User-Agent: lab' http://127.0.0.1:19100/
sleep 0.3
loop "\] $w#"
# accept: client_header_timeout (60s) on the read event; the request: header done deletes it;
# keepalive: keepalive_timeout (75s); EOF from the client closes the connection
expect "kevent waits for the nearest timer: 60000 ms after accept, 75000 ms in keepalive, forever after close" \
    "$(loop "\] $w#" | sed -n 's/^kevent timer: \(-*[0-9]*\), changes: [0-9]*/\1/p' | tr '\n' ' ')" "60000 75000 -1 "

step "a timer fires"
: > logs/error.log
python3 client.py silent 19101
sleep 0.2
loop "\] $w#"
expect "kevent returns 0 events after 1000 ms, the expired timer runs the read handler" \
    "$(loop "\] $w#" | grep -cE '^kevent timer: 1000, |^kevent events: 0$|client timed out')" "3"

step "pipelined requests go through the posted queue"
: > logs/error.log
python3 client.py pipeline 19100
sleep 0.2
loop "\] $w#"
expect "the second request is posted and runs at the end of the same loop iteration" \
    "$(loop "\] $w#" | grep -cE '^pipelined request$|^post event$|^posted event$')" "3"

step "the master talks to workers over the channel"
: > logs/error.log
kill -USR1 "$(master_pid)"
sleep 0.3
loop "\] $w#" | grep 'channel command'
# ngx_signal_worker_processes: QUIT -> NGX_CMD_QUIT 3, TERM -> 4, USR1 -> NGX_CMD_REOPEN 5
expect "USR1 becomes channel command 5 (NGX_CMD_REOPEN)" \
    "$(loop "\] $w#" | grep -c '^channel command: 5$')" "1"
stop

step "reuseport gives every worker its own listening socket"
start conf/workers.conf
sleep 0.3
lsof -nP -a -p "$(master_pid)" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' | sort | uniq -c | awk '{ print $2 ": " $1 " socket(s) in the master" }'
expect "four sockets for the reuseport listener, one for the shared one" \
    "$(lsof -nP -a -p "$(master_pid)" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' | sort | uniq -c | awk '{ printf "%s ", $1 }')" "4 1 "
stop

step "accept_mutex: one worker listens, the others retry every 500 ms"
start conf/mutex.conf
sleep 1.2
for i in 1 2 3; do curl -s -o /dev/null http://127.0.0.1:19104/; done
sleep 0.3
# the mutex can change hands while connections arrive, so look at the last attempt and the
# last wait of each worker once the server is idle again
mutex_state() {
    for w in $(worker_pids); do
        printf '%s %s\n' \
            "$(grep -a "\] $w#[0-9]*: accept mutex lock" logs/error.log | tail -1 | sed -E 's/.*accept mutex (locked|lock failed).*/\1/')" \
            "$(grep -a "\] $w#[0-9]*: kevent timer" logs/error.log | tail -1 | sed -E 's/.*kevent timer: (-?[0-9]+),.*/\1/')"
    done | sort
}
mutex_state | awk '{ t = $NF; $NF = ""; printf "last attempt: %-12s then kevent timer: %s\n", $0, t }'
# ngx_process_events_and_timers: the holder keeps the listening socket and sleeps until an
# event; a worker that failed to lock waits at most accept_mutex_delay (500 ms) and retries
expect "the holder sleeps until a connection arrives, the other wakes every 500 ms" \
    "$(mutex_state | tr '\n' ',')" "lock failed 500,locked -1,"
stop
