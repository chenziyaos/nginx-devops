# ops-11: access log formats and escaping, timing variables, conditional and buffered
# logs, stub_status, log reopening, json_set.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:18220
mkdir -p out/run/www
head -c 3000 /dev/zero > out/run/www/slowbody
printf "slow\n" > out/run/www/slowhead

start

step "default escaping, escape=json, escape=none"
# a user agent with a quote, a backslash, a control byte (0x01) and UTF-8 "é" (0xC3 0xA9)
ua=$(printf 'a"b\\c\001d\303\251')
curl -s -o /dev/null -A "$ua" $U/esc
sleep 0.1
echo "default: $(cat logs/esc_default.log)"
echo "json:    $(cat logs/esc_json.log)"
echo "none:    $(od -An -tx1 logs/esc_none.log | tr -s ' ' | sed 's/^ //') (hex bytes)"
expect "default writes \\xHH for \" \\ control bytes and bytes >= 0x80; json uses \\\" \\\\ \\u0001 and keeps UTF-8" \
    "$(cat logs/esc_default.log) | $(cat logs/esc_json.log)" \
    'a\x22b\x5Cc\x01d\xC3\xA9 | {"ua":"a\"b\\c\u0001dé"}'

step "bytes_sent and body_bytes_sent"
hsize=$(curl -s -o /dev/null -w '%{size_header}' $U/sizes)
sleep 0.1
read -r st bs bbs < logs/sizes.log
echo "log: status=$st bytes_sent=$bs body_bytes_sent=$bbs; curl saw a header of $hsize bytes"
expect "bytes_sent is the header plus the body" "$bs" "$(( hsize + bbs ))"

step "request_time and upstream times"
curl -s -o /dev/null $U/slowbody
curl -s -o /dev/null $U/slowhead
curl -s -o /dev/null $U/slowhead
sleep 0.1
# the times vary from run to run (limit_rate and limit_req count whole seconds), so each
# line is printed as comparisons against fixed bounds
check() {
    awk '{
        for (i = 2; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
        printf "%-9s uct %s 0.9, uht %s 0.9, urt %s 0.9, rt %s 0.9, rt >= urt - 0.002: %s\n", $1,
            (v["uct"] < 0.9 ? "<" : ">="), (v["uht"] < 0.9 ? "<" : ">="), (v["urt"] < 0.9 ? "<" : ">="),
            (v["rt"] < 0.9 ? "<" : ">="), (v["rt"] >= v["urt"] - 0.002 ? "yes" : "no")
    }' logs/times.log
}
check
expect "a slow body shows in urt and rt only; a delayed header shows in uht as well" \
    "$(check | awk '{ print $6, $9, $12 }' | tr '\n' ' ')" "< >= >= < < < >= >= >= "

step "one value per upstream attempt"
curl -s -o /dev/null $U/tries
sleep 0.1
sed -E 's/[0-9]+\.[0-9]{3}/T/g' logs/tries.log
expect "the dead server and the live one are both listed, separated by \", \"" \
    "$(sed -E 's/[0-9]+\.[0-9]{3}/T/g' logs/tries.log)" \
    "addr=[127.0.0.1:18229, 127.0.0.1:18221] status=[502, 200] urt=[T, T]"

step "conditional logging"
for p in /cond/index.html /cond/missing /cond/; do curl -s -o /dev/null $U$p; done
sleep 0.1
cat logs/cond.log
expect "only the 4xx line is written" "$(cat logs/cond.log | tr '\n' ' ')" "404 /cond/missing "

step "buffered log with flush=3s"
curl -s -o /dev/null $U/buf
sleep 0.2
echo "0.2 s after the request: $(wc -l < logs/buf.log | tr -d ' ') lines"
sleep 3.3
echo "3.5 s after the request: $(wc -l < logs/buf.log | tr -d ' ') lines"
expect "the line waits in memory until the flush timer fires" \
    "$(wc -l < logs/buf.log | tr -d ' ')" "1"

step "log_not_found"
: > logs/error.log
curl -s -o /dev/null $U/nf/x; curl -s -o /dev/null $U/nf2/x
sleep 0.1
errlog 'open\(\)' | sed -E "s#$LAB/#\$LAB/#g; s/\\*[0-9]+ //; s/, client: .*//"
expect "only the location without log_not_found off logs the missing file" \
    "$(grep -c 'nf/x' logs/error.log) $(grep -c 'nf2/x' logs/error.log || true)" "1 0"

step "stub_status"
sleep 0.5    # let the connections of the earlier steps close
# two status requests on one keepalive connection, then one on a new connection
curl -s $U/status $U/status > out/run/st.txt
curl -s $U/status >> out/run/st.txt
cat out/run/st.txt | sed -n '1,4p'
# accepts handled requests of the three reads
nums() { awk 'NR % 4 == 3 { print $1, $2, $3 }' out/run/st.txt; }
nums
expect "a keepalive request adds a request but no connection; a new connection adds both" \
    "$(nums | awk 'NR == 1 { a = $1; r = $3 } NR == 2 { printf "%d %d ", $1 - a, $3 - r } NR == 3 { printf "%d %d", $1 - a, $3 - r }')" \
    "0 1 1 2"

step "reopening logs with USR1"
: > logs/access.log
curl -s -o /dev/null $U/rot/1
sleep 0.1
mv logs/access.log logs/access.log.1
curl -s -o /dev/null $U/rot/2
sleep 0.1
echo "after mv:   access.log.1 has $(wc -l < logs/access.log.1 | tr -d ' ') lines, access.log exists: $([[ -e logs/access.log ]] && echo yes || echo no)"
kill -USR1 "$(master_pid)"
for i in $(seq 20); do [[ -e logs/access.log ]] && break; sleep 0.1; done
curl -s -o /dev/null $U/rot/3
sleep 0.1
echo "after USR1: access.log.1 has $(wc -l < logs/access.log.1 | tr -d ' ') lines, access.log has $(wc -l < logs/access.log | tr -d ' ')"
errlog 'reopening logs' | sed -E 's/from [0-9]+/from <pid>/' | head -1
expect "the renamed file keeps receiving lines until USR1 reopens the path" \
    "$(cat logs/access.log.1 | tr '\n' ' ')| $(cat logs/access.log | tr '\n' ' ')" "200 /rot/1 200 /rot/2 | 200 /rot/3 "

step "json_set"
curl -s -o /dev/null -H 'X-Ctx: {"tenant": {"id": "t-42"}, "items": ["a1", "b2"]}' $U/json
curl -s -o /dev/null -H 'X-Ctx: {"tenant": ' $U/json
curl -s -o /dev/null $U/json
sleep 0.1
cat logs/json.log
expect "a path picks one value; broken or missing JSON gives \"-\"" \
    "$(cat logs/json.log | tr '\n' ' ')" "tenant=t-42 first_item=a1 tenant=- first_item=- tenant=- first_item=- "

stop
