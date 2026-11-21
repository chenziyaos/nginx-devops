# ops-09: limit_req and limit_conn, one config per scenario (conf/*.conf).
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:18180/

# per-request verdicts from the access log ("$status $limit_*_status"), counted
verdicts() { sort logs/access.log | uniq -c | awk '{ print $1 "x " $2 " " $3 }'; }

step "return answers before limit_req runs"
start conf/return.conf
r=$(seq_codes 5 "$U"); echo "$r"
expect "return ends the request in REWRITE, limit_req never runs" "$r" "200 200 200 200 200"
stop

step "no burst: 5 requests in a row"
start conf/no-burst.conf
r=$(seq_codes 5 "$U"); echo "$r"
expect "without burst only the first request fits" "$r" "200 503 503 503 503"
errlog 'limiting requests' | head -1 | sed -E 's/excess: [0-9.]+/excess: <n>/; s/\*[0-9]+ /*N /'
stop

step "burst=5: 8 requests at once"
start conf/burst.conf
fire 8 "$U"
verdicts
slowest_at_least 4.5
expect "burst=5 lets burst+1 through, 5 of them queued" "$(count_log '^200 DELAYED') $(count_log '^200 PASSED') $(count_log '^503 REJECTED')" "5 1 2"
errlog 'delaying request' | sed -E 's/, client.*//; s/\*[0-9]+ /*N /' \
    | awk '{ match($0, /excess: [0-9.]+/); x = substr($0, RSTART + 8, RLENGTH - 8);
             sub(/excess: [0-9.]+/, sprintf("excess: ~%d", x + 0.5)); print }'
stop

step "burst=5 nodelay: 8 requests at once"
start conf/nodelay.conf
fire 8 "$U"
verdicts
all_below 0.5
expect "nodelay passes the same 6 at once" "$(count_log '^200 PASSED') $(count_log '^503 REJECTED')" "6 2"
stop

step "burst=5 delay=2: 8 requests at once"
start conf/delay.conf
fire 8 "$U"
verdicts
slowest_at_least 2.5
expect "delay=2 passes excess 0..2 at once and queues 3..5" "$(count_log '^200 PASSED') $(count_log '^200 DELAYED') $(count_log '^503 REJECTED')" "3 3 2"
stop

step "burst=5 nodelay: the queue drains at the rate"
start conf/nodelay.conf
fire 8 "$U"
sleep 2.5
echo "after 2.5 s, 4 more at once:"
# 2.5 s at 1r/s drains 2.5 requests worth of excess, so at least 2 of the 4 pass;
# a loaded machine only adds time, which can let a third or fourth one through
fire 4 "$U" > /dev/null
awk '$1 == 200' out/run/fire.txt | wc -l | awk '{ print "at least 2 passed: " ($1 >= 2 ? "yes" : "no") }'
stop

step "limit_req_status 429"
start conf/status.conf
r=$(seq_codes 3 "$U"); echo "$r"
expect "limit_req_status replaces 503" "$r" "200 429 429"
stop

step "limit_req_dry_run on"
start conf/dry-run.conf
seq_codes 3 "$U"
accesslog
errlog 'dry run' | head -1 | sed -E 's/excess: [0-9.]+/excess: <n>/; s/\*[0-9]+ /*N /; s/, client.*//'
stop

step "two zones: the stricter one decides"
start conf/two-zones.conf
fire 8 "$U"
verdicts
expect "perserver burst=2 lets 3 through" "$(count_status 200)" "3"
errlog 'limiting requests' | sed -E 's/.*by zone/by zone/; s/, client.*//' | sort | uniq -c | awk '{ print $1 "x " $2 " " $3 " " $4 }'
stop

step "limit_conn 1: 3 HTTP/1.1 requests at once"
start conf/conn.conf
fire 3 http://127.0.0.1:18180/slow.txt
verdicts
expect "limit_conn 1 keeps one request in progress" "$(count_status 200)" "1"
errlog 'limiting connections' | head -1 | sed -E 's/\*[0-9]+ /*N /; s/, client.*//'
stop

step "limit_conn 1: 3 HTTP/2 streams on one connection"
start conf/conn.conf
curl -s --http2-prior-knowledge --parallel --parallel-immediate -o /dev/null -o /dev/null -o /dev/null \
    -w '%{http_code} HTTP/%{http_version}\n' \
    http://127.0.0.1:18181/slow.txt http://127.0.0.1:18181/slow.txt http://127.0.0.1:18181/slow.txt \
    | sort | uniq -c | awk '{ print $1 "x " $2 " " $3 }'
verdicts
stop
