# ops-03: master and workers, what each signal does, reload with and without errors,
# binary upgrade and the control API. Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:18060

# the error.log lines of the process lifecycle, without timestamps, pids and the event method
lifecycle() {
    grep -aE '\[(notice|emerg|alert)\]' logs/error.log \
        | grep -avE 'SIGIO|signal process started|event method' \
        | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /' \
        | sed -E -e 's/(received from|process) [0-9]+/\1 N/' -e "s#$LAB/#\$LAB/#g"
}

# result: "complete" when the background download got the whole file, else "cut"
result() { awk '{ print $1, ($2 < 1048576 ? "cut" : "complete") }' out/run/slow.txt; }

# slow PATH: start a 5 s download in the background and return once the first bytes arrived;
# its result goes to out/run/slow.txt
slow() {
    rm -f out/run/slow.bin
    curl -s -o out/run/slow.bin -w '%{http_code} %{size_download}\n' "$U$1" > out/run/slow.txt &
    local i
    for i in $(seq 50); do [[ -s out/run/slow.bin ]] && break; sleep 0.1; done
}

# alive PID...: how many of these processes still exist
alive() { local n=0 p; for p in "$@"; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; echo "$n"; }

mkdir -p out/run/big
head -c 1048576 /dev/zero > out/run/big/f.bin

step "one master, worker_processes workers"
start
m=$(master_pid); w=$(worker_pids)
# parent of each process: the master is a daemon (parent 1), workers are its children
ps -o ppid=,command= -p "$m,${w// /,}" | sed -E "s#$NGINX#\$NGINX#; s#$LAB/#\$LAB/#; s/ +$//" \
    | awk -v m="$m" '{ p = ($1 == m ? "master" : $1); $1 = ""; print "parent=" p $0 }' | sort
expect "two workers, both children of the master" \
    "$(pgrep -P "$m" | wc -l | tr -d ' ')" "2"
stop

step "worker_processes auto and the cache processes"
start conf/auto.conf
m=$(master_pid)
sleep 0.3
ncpu=$(getconf _NPROCESSORS_ONLN)
ps -o command= -p "$(pgrep -P "$m" | tr '\n' ',' | sed 's/,$//')" | sed 's/ *$//' | sort | uniq -c \
    | sed -E "s/^ *$ncpu nginx: worker/  NCPU nginx: worker/; s/^ +/  /"
expect "auto starts one worker per online CPU, proxy_cache_path adds a manager and a loader" \
    "$(ps -o command= -p "$(pgrep -P "$m" | tr '\n' ',' | sed 's/,$//')" | grep -c 'worker process') $(pgrep -P "$m" | wc -l | tr -d ' ')" \
    "$ncpu $((ncpu + 2))"
stop

step "reload: new workers start, old ones finish their requests"
start
m=$(master_pid); old=$(worker_pids)
before=$(curl -s $U/ | cut -d' ' -f1)
slow /big/f.bin
reload_nowait conf/v2.conf
sleep 0.5
new=$(worker_pids)
echo "master unchanged: $([[ $(master_pid) == "$m" ]] && echo yes || echo no)"
echo "old workers still alive during the download: $(alive $old) of 2"
echo "answers now: $(curl -s $U/ | cut -d' ' -f1)"
wait
echo "download: $(result)"
sleep 0.3
echo "old workers alive after it: $(alive $old)"
lifecycle | grep -vE 'start worker processes$' | sed -n '/SIGHUP/,$p'
expect "same master, new config answers, the in-flight download completes, then old workers exit" \
    "$before $(curl -s $U/ | cut -d' ' -f1) $(result) $(alive $old)" "v1 v2 200 complete 0"
stop

step "nginx -s reload with a broken config"
start
w=$(worker_pids)
reload_nowait conf/bad.conf 2>&1 | sed "s#$LAB/#\$LAB/#g" || true
echo "workers unchanged: $([[ $(worker_pids) == "$w" ]] && echo yes || echo no)"
expect "the signaller parses the config itself and does not send HUP" \
    "$(grep -ac 'SIGHUP' logs/error.log || true)" "0"

step "HUP with a broken config"
: > logs/error.log
kill -HUP "$(master_pid)"
sleep 0.5
lifecycle | grep -E 'SIGHUP|reconfiguring|emerg'
echo "workers unchanged: $([[ $(worker_pids) == "$w" ]] && echo yes || echo no), answers: $(curl -s $U/ | cut -d' ' -f1)"
expect "the master logs the error and keeps the old workers and config" \
    "$([[ $(worker_pids) == "$w" ]] && echo same) $(curl -s $U/ | cut -d' ' -f1)" "same v1"
stop

step "worker_shutdown_timeout comes from the old config"
start conf/shutdown-timeout.conf
slow /big/f.bin
reload conf/nginx.conf
wait
cut1=$(result); echo "started with timeout 1s, download: $cut1"
stop
start conf/nginx.conf
slow /big/f.bin
reload conf/shutdown-timeout.conf
wait
cut2=$(result); echo "reloaded into timeout 1s, download: $cut2"
expect "only workers that run a config with the timeout close connections after it" "$cut1 / $cut2" "200 cut / 200 complete"
stop

step "TERM and QUIT"
start
slow /big/f.bin
kill -TERM "$(master_pid)"
wait
term=$(result); echo "TERM during a download: $term"
for i in $(seq 50); do [[ -e logs/nginx.pid ]] || break; sleep 0.1; done
start
slow /big/f.bin
m=$(master_pid)
kill -QUIT "$m"
sleep 0.5
echo "QUIT: new connections refused: $(curl -s -o /dev/null -w '%{http_code}' $U/ || true), master alive: $(alive "$m")"
wait
quit=$(result); echo "QUIT during a download: $quit"
for i in $(seq 50); do kill -0 "$m" 2>/dev/null || break; sleep 0.1; done
expect "TERM closes connections at once, QUIT stops accepting and waits" "$term / $quit" "200 cut / 200 complete"

step "USR1 reopens the log files"
start
curl -s $U/ > /dev/null
mv logs/access.log logs/access.log.1
curl -s $U/ > /dev/null
echo "after mv: access.log exists: $([[ -e logs/access.log ]] && echo yes || echo no), lines in access.log.1: $(wc -l < logs/access.log.1 | tr -d ' ')"
kill -USR1 "$(master_pid)"
sleep 0.5
curl -s $U/ > /dev/null
echo "after USR1: lines in access.log: $(wc -l < logs/access.log | tr -d ' '), in access.log.1: $(wc -l < logs/access.log.1 | tr -d ' ')"
expect "workers write to the renamed file until USR1, then to a new access.log" \
    "$(wc -l < logs/access.log.1 | tr -d ' ') $(wc -l < logs/access.log | tr -d ' ')" "2 1"
stop

step "a killed worker is replaced"
start
: > logs/error.log
m=$(master_pid); w1=$(worker_pids | awk '{ print $1 }')
kill -KILL "$w1"
sleep 0.5
lifecycle | grep -E 'exited|start worker process' | sed -E 's/start worker process [0-9]+/start worker process NEW/'
expect "the master notices SIGCHLD and starts a new worker" \
    "$(pgrep -P "$m" | wc -l | tr -d ' ') $(alive "$w1")" "2 0"
stop

step "binary upgrade: USR2, WINCH, QUIT"
start
old_m=$(master_pid); old_w=$(worker_pids)
kill -USR2 "$old_m"
for i in $(seq 50); do [[ -s logs/nginx.pid && $(master_pid) != "$old_m" ]] && break; sleep 0.1; done
sleep 0.5
new_m=$(master_pid)
echo "after USR2: nginx.pid.oldbin holds the old master: $([[ $(cat logs/nginx.pid.oldbin) == "$old_m" ]] && echo yes || echo no)"
echo "new master is a child of the old one: $([[ $(ps -o ppid= -p "$new_m" | tr -d ' ') == "$old_m" ]] && echo yes || echo no)"
echo "masters alive: $(alive "$old_m" "$new_m"), old workers alive: $(alive $old_w), new workers: $(pgrep -P "$new_m" | wc -l | tr -d ' ')"
kill -WINCH "$old_m"
sleep 0.5
echo "after WINCH: old workers alive: $(alive $old_w), old master alive: $(alive "$old_m")"
kill -QUIT "$old_m"
for i in $(seq 50); do kill -0 "$old_m" 2>/dev/null || break; sleep 0.1; done
echo "after QUIT: old master alive: $(alive "$old_m"), oldbin file left: $([[ -e logs/nginx.pid.oldbin ]] && echo yes || echo no), answers: $(curl -s $U/ | cut -d' ' -f1)"
expect "two masters share the sockets until the old one is told to quit" \
    "$(alive "$old_m") $(alive "$new_m") $(curl -s $U/ | cut -d' ' -f1)" "0 1 v1"
stop

step "control API"
ln -sfn nginx.conf conf/.active.conf
ngx -c conf/.active.conf -l 127.0.0.1:18079
for i in $(seq 50); do [[ -s logs/nginx.pid ]] && break; sleep 0.1; done
C=http://127.0.0.1:18079
echo "GET /1/nginx: $(curl -s $C/1/nginx)"
procs() {
    curl -s $C/1/control/processes | python3 -c 'import json, sys
for p in json.load(sys.stdin): print("  %s exiting=%s" % (p["name"], str(p["exiting"]).lower()))'
}
echo "GET /1/control/processes:"; procs
ln -sfn bad.conf conf/.active.conf
bad=$(curl -s -o out/run/patch.json -w '%{http_code}' -X PATCH $C/1/control/config)
echo "PATCH with bad.conf: $bad $(sed -E "s#$LAB/#\$LAB/#g; s/[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /" out/run/patch.json)"
ln -sfn v2.conf conf/.active.conf
slow /big/f.bin
good=$(curl -s -o out/run/patch.json -w '%{http_code}' -X PATCH $C/1/control/config)
sleep 0.5
echo "PATCH with v2.conf during a download: $good, answers: $(curl -s $U/ | cut -d' ' -f1)"
echo "GET /1/control/processes:"; procs | sort | uniq -c | sed -E 's/^ +/  /'
wait
expect "PATCH reloads synchronously and returns the errors of a failed reload" \
    "$bad $good $(curl -s $U/ | cut -d' ' -f1)" "422 200 v2"
stop
