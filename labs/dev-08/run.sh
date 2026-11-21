# dev-08: limit_req internals seen through the debug log, one config per scenario (conf/*.conf).
# Expected values come from src/http/modules/ngx_http_limit_req_module.c, see HYPOTHESES.md.
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:19160

# "limit_req[n]: rc excess" debug lines; the excess is rounded to a whole request because
# a few milliseconds between requests drain a few thousandths at most
lr_lines() {
    errlog 'limit_req\[[0-9]\]' | sed -E 's/^\[debug\] \*[0-9]+ //' \
        | awk '{ printf "%s %s ~%d\n", $1, $2, $3 + 0.5 }'
}

# excess values (rounded) of the matching error.log lines, on one line
excess_of() {
    errlog "$1" | grep -oE 'excess: [0-9.]+' | awk '{ printf "%s%d", (NR > 1 ? " " : ""), $2 + 0.5 } END { print "" }'
}

verdicts() { awk '{ print $1, $2 }' logs/access.log | sort | uniq -c | awk '{ print $1 "x " $2 " " $3 }'; }

step "each passed request adds 1000, a rejected one adds nothing"
start conf/excess.conf
r=$(seq_codes 8 "$U/"); echo "$r"
lr_lines
expect "burst=5 nodelay: the first 6 pass, then 503" "$r" "200 200 200 200 200 200 503 503"
expect "rc per request: NGX_OK (0) six times, then NGX_BUSY (-3)" \
    "$(lr_lines | awk '{ printf "%s ", $2 }')" "0 0 0 0 0 0 -3 -3 "
expect "excess seen by each request: a new key starts at 0, rejected ones do not raise it" \
    "$(lr_lines | awk '{ printf "%s ", $3 }')" "~0 ~1 ~2 ~3 ~4 ~5 ~6 ~6 "

step "1r/m drains 16 thousandths per second"
sleep 6
r=$(code "$U/"); echo "$r"
x=$(errlog 'limiting requests' | tail -1 | grep -oE 'excess: [0-9.]+' | awk '{ print $2 }')
# ms between the 6th (last accepted) request and this one, from $msec in logs/msec.log
# ($msec is when the request was logged; a 503 is logged only after lingering close)
ms=$(awk '{ s = $1 - $2 } $3 == 200 { t = s } END { print int((s - t) * 1000 + 0.5) }' logs/msec.log)
# excess stored by the 6th request (slightly below 5 when the requests were not instant)
e6=$(errlog 'limit_req\[0\]: 0 ' | tail -1 | awk '{ print $NF }')
want16=$(awk -v e="$e6" -v ms="$ms" 'BEGIN { printf "%.3f", (e * 1000 + 1000 - int(16 * ms / 1000)) / 1000 }')
want1667=$(awk -v e="$e6" -v ms="$ms" 'BEGIN { printf "%.3f", (e * 1000 + 1000 - int(16.667 * ms / 1000)) / 1000 }')
near() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; print (d <= 0.002 && d >= -0.002) ? "yes" : "no" }'; }
echo "within 0.002 of rate 16: $(near "$x" "$want16"); within 0.002 of rate 16.667: $(near "$x" "$want1667")"
expect "still rejected after 6 s" "$r" "503"
expect "drained = 16 * ms / 1000: 1r/m is stored as 16, not 16.667" \
    "$(near "$x" "$want16") $(near "$x" "$want1667")" "yes no"
stop

step "an internal redirect does not count twice"
start conf/once.conf
body=$(get "$U/missing"); echo "$body"
accesslog
expect "error_page sends /missing to /fallback" "$body" "fallback"
expect "only one limit_req lookup for the whole request" "$(lr_lines | wc -l | tr -d ' ')" "1"
stop

step "two zones: only the last one is charged, a rejection rolls the others back"
start conf/two-zones.conf
r=$(seq_codes 4 "$U/both"); echo "$r"
lr_lines
expect "narrow (burst 0) rejects from the second request" "$r" "200 503 503 503"
expect "wide answers NGX_AGAIN (-2), narrow answers OK then BUSY" \
    "$(lr_lines | awk '{ printf "%s%s ", $1, $2 }')" \
    "limit_req[0]:-2 limit_req[1]:0 limit_req[0]:-2 limit_req[1]:-3 limit_req[0]:-2 limit_req[1]:-3 limit_req[0]:-2 limit_req[1]:-3 "
expect "wide sees ~1 every time: the three rejected requests were never added" \
    "$(lr_lines | awk '$1 == "limit_req[0]:" { printf "%s ", $3 }')" "~0 ~1 ~1 ~1 "
: > logs/error.log
r=$(code "$U/wide"); echo "/wide: $r"
lr_lines
expect "wide's stored excess is one request, not four" "$(lr_lines | awk '{ print $3 }')" "~1"
stop

step "delay=1: excess above 1 becomes a timer of (excess - 1) / rate"
start conf/delay.conf
fire 5 "$U/"
verdicts
# arrivals spread over up to ~1 s on a busy machine: the bound is 1 s below the formula's 3 s
slowest_at_least 2
echo "delaying request, excess: $(excess_of 'delaying request')"
# the timer that ngx_add_timer() sets right after each "delaying request" line, in whole seconds
timers=$(awk '/delaying request/ { f = 1; next }
              f && /event timer add/ { split($0, a, ": "); split(a[length(a)], b, ":");
                                        printf "%s%d", (n++ ? " " : ""), b[1] / 1000 + 0.5; f = 0 }
              END { print "" }' logs/error.log)
echo "delay timers (s): $timers"
expect "2 pass at once (excess 0 and 1), 3 are delayed, none rejected" \
    "$(count_log '^200 PASSED') $(count_log '^200 DELAYED') $(count_log '^503')" "2 3 0"
expect "delayed requests had excess ~2, ~3, ~4" "$(excess_of 'delaying request')" "2 3 4"
expect "timers are (excess - delay) * 1000 / rate ms: ~1, ~2, ~3 s" "$timers" "1 2 3"
stop

step "a full zone evicts the least recently used key"
start conf/evict.conf
r=$(seq_codes 2 "$U/?k=victim"); echo "victim: $r"
curl -s -o /dev/null -w '%{http_code}\n' "$U/?k=[1-3000]" | sort | uniq -c | awk '{ print $1 "x " $2 }' > out/run/flood.txt
echo "3000 new keys: $(cat out/run/flood.txt)"
echo "\"could not allocate node\" lines: $(errlog 'could not allocate node' | wc -l | tr -d ' ')"
recent=$(code "$U/?k=3000"); echo "k=3000 again: $recent"
: > logs/error.log
again=$(code "$U/?k=victim"); echo "victim again: $again"
lr_lines
expect "victim is limited before the flood" "$r" "200 503"
expect "every new key passes: allocation never fails, the oldest node is deleted instead" \
    "$(cat out/run/flood.txt) $(errlog 'could not allocate node' | wc -l | tr -d ' ')" "3000x 200 0"
expect "the most recent key is still in the zone" "$recent" "503"
expect "victim was evicted and starts again from excess 0" "$again $(lr_lines | awk '{ print $2, $3 }')" "200 0 ~0"

step "how many keys a 128k zone holds"
# probe k=3000, 2999, ... : a key still in the zone answers 503 (and only moves to the queue
# head), the first evicted one answers 200; so the leading 503s count the keys that are left
seq 3000 -1 1 | awk -v u="$U" '{ print "url = \"" u "/?k=" $1 "\"\noutput = /dev/null" }' > out/run/probe.cfg
curl -s -K out/run/probe.cfg -w '%{http_code}\n' > out/run/probe.txt
left=$(awk '$1 != 503 { exit } { n++ } END { print n + 0 }' out/run/probe.txt)
echo "keys left besides victim: $left"
expect "128k on 16 KB pages: 761 nodes of 128 bytes, victim included" "$left" "760"
stop

step "reload keeps a zone with the same name, size and key"
start conf/keep.conf
r=$(seq_codes 2 "$U/"); echo "before reload: $r"
reload conf/keep.conf
after=$(code "$U/"); echo "after reload: $after"
expect "state survives a reload" "$r $after" "200 503 503"

step "a different key with the same size is refused"
w=$(worker_pids)
reload_nowait conf/keep-newkey.conf
sleep 1
errlog 'uses the' | sed -E 's/ in .*//'
after=$(code "$U/"); echo "after refused reload: $after"
expect "the master rejects the new config" "$(errlog 'uses the' | wc -l | tr -d ' ')" "1"
expect "old workers keep serving with the old state" "$(worker_pids) $after" "$w 503"

step "a different size gets a new, empty zone"
reload conf/keep-resized.conf
after=$(code "$U/"); echo "after resize: $after"
expect "resizing drops the old state, no key check" "$after $(errlog 'uses the' | wc -l | tr -d ' ')" "200 1"
stop
