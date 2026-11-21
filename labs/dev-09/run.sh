# dev-09: the upstream machinery. rr.c drives the round robin balancer of the build directly
# (linked by labs/ctest.sh); the rest reads the debug log of the front server (logs/front.log)
# and the backend log, where c= is $connection_requests of the backend connection.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

# trace RE: front.log lines matching RE, without times, pids, connection numbers, pointers,
# descriptors and the client/request suffix
trace() {
    grep -aE "$1" logs/front.log \
        | sed -E -e 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /' -e 's/^(\[[a-z]+\]) \*[0-9]+ /\1 /' \
            -e 's/ [0-9A-F]{16}( |$)/\1/' -e 's/, fd:[0-9]+ #[0-9]+//' -e 's/(, client: | while ).*//' \
            -e 's/^\[debug\] //'
}
# conns URL...: request each URL in turn, print the backend's c= values on one line
conns() {
    local u
    : > logs/backend.log
    for u in "$@"; do curl -s -o /dev/null "$u"; done
    awk '{ sub(/^c=/, "", $2); printf "%s ", $2 }' logs/backend.log
}
F=http://127.0.0.1:19180

step "smooth weighted round robin, called directly"
ctest rr.c swrr 5 1 1 7 | tee out/run/swrr.txt
expect "weights 5 1 1 pick A A B A C A A and end at 0 0 0" \
    "$(awk 'NR > 1 { printf "%s ", $2 }' out/run/swrr.txt)$(tail -1 out/run/swrr.txt | awk '{ print $3, $4, $5 }')" \
    "A A B A C A A 0 0 0"

step "a failure lowers effective_weight, every pass adds one back"
ctest rr.c fail | tee out/run/fail.txt
expect "effective_weight 5 - 5/2 = 3, the retry picks B, then A recovers 4, 5" \
    "$(grep -o 'effective=[0-9]*' out/run/fail.txt) $(awk '/retry/ { print $2 }' out/run/fail.txt) $(awk '$1 == "2:" || $1 == "3:" { printf "%s ", $3 }' out/run/fail.txt)" \
    "effective=3 B 4 5 "

step "one request tries each server once"
ctest rr.c tries | tee out/run/tries.txt
expect "tried 0x1 0x3 0x7, tries 2 1 0, then NGX_BUSY for this and the next request" \
    "$(grep -o 'tried=0x[0-9]*' out/run/tries.txt | tr '\n' ' ')$(grep -o 'tries=[0-9]' out/run/tries.txt | tail -3 | tr '\n' ' ')$(grep -c NGX_BUSY out/run/tries.txt)" \
    "tried=0x1 tried=0x3 tried=0x7 tries=2 tries=1 tries=0 2"

step "a sticky hint skips the reweighting after the first time"
ctest rr.c sticky | tee out/run/sticky.txt
expect "three sticky picks of A leave -2 1 1, then B and C" \
    "$(awk 'NR > 1 { printf "%s(%s %s %s) ", $3, $4, $5, $6 }' out/run/sticky.txt)" \
    "A(-2 1 1) A(-2 1 1) A(-2 1 1) B(-1 -1 2) C(0 0 0) "

mkdir -p out/run/files
dd if=/dev/zero of=out/run/files/big.bin bs=1048576 count=4 2> /dev/null
cp out/run/files/big.bin out/run/files/xab.bin
# the [warn] for stk_bad goes to stderr at startup; the step below shows it with nginx -t
start 2> out/run/start.err
sleep 0.3

step "one proxied request, step by step"
: > logs/front.log
curl -s -o /dev/null $F/one/a
UP='http init upstream|keepalive peer|get rr peer|connect to|http upstream (connect|send request|send request handler|dummy handler|process header|process upstream)|http proxy status|finalize http (upstream|proxy) request|free rr peer|close http upstream'
trace "$UP" | tee out/run/first.txt
expect "a new connection: connect returns NGX_AGAIN (-2), the request waits for the write event" \
    "$(grep -c 'connect to' out/run/first.txt) $(grep -o 'http upstream connect: -*[0-9]*' out/run/first.txt) $(grep -A1 'connect: ' out/run/first.txt | tail -1)" \
    "1 http upstream connect: -2 http upstream send request handler"

step "the second request takes the cached connection"
: > logs/front.log
curl -s -o /dev/null $F/one/a
trace "$UP" | tee out/run/second.txt
expect "no connect, NGX_DONE (-4), the request is sent at once" \
    "$(grep -c 'connect to' out/run/second.txt) $(grep -o 'http upstream connect: -*[0-9]*' out/run/second.txt) $(grep -A1 'connect: ' out/run/second.txt | tail -1)" \
    "0 http upstream connect: -4 http upstream send request"

step "next upstream: free the failed peer, get another one"
: > logs/front.log
: > logs/access.log
curl -s -o /dev/null $F/dead/a
curl -s -o /dev/null $F/dead/a
trace 'get rr peer, try|connect to|connect\(\) failed|next upstream|free rr peer|temporarily disabled'
cat logs/access.log
expect "free rr peer 2 4 after the refused connect, the second request goes straight to 19181" \
    "$(trace 'free rr peer 2' | head -1) | $(sed -n 1p logs/access.log | cut -d' ' -f3-) | $(sed -n 2p logs/access.log | cut -d' ' -f3-)" \
    "free rr peer 2 4 | ups=127.0.0.1:19198, 127.0.0.1:19181 st=502, 200 | ups=127.0.0.1:19181 st=200"

step "which upstreams have a connection cache"
: > logs/front.log
echo "proxy_pass http://127.0.0.1:19181/: $(conns $F/direct/a $F/direct/a $F/direct/a)"
echo "keepalive 0:                     $(conns $F/nokeep/a $F/nokeep/a $F/nokeep/a)"
echo "keepalive 16:                    $(conns $F/shared/a $F/shared/a $F/shared/a)"
expect "an implicit upstream and keepalive 0 open a connection per request" \
    "$(conns $F/direct/a $F/direct/a)| $(conns $F/nokeep/a $F/nokeep/a)" "1 1 | 1 1 "

step "the default cache is local to the location"
echo "default (local), /loc1/ /loc2/ /loc1/ /loc2/:     $(conns $F/loc1/a $F/loc2/a $F/loc1/a $F/loc2/a)"
echo "keepalive 16, /shared/ /shared2/ /shared/ /shared2/: $(conns $F/shared/a $F/shared2/a $F/shared/a $F/shared2/a)"
expect "two locations, one upstream: separate connections unless keepalive N is written" \
    "$(conns $F/loc1/a $F/loc2/a)| $(conns $F/shared2/a)" "3 3 | 8 "

step "when a connection is not kept"
: > logs/front.log
echo "keepalive_requests 2:      $(conns $F/reqs/a $F/reqs/a $F/reqs/a $F/reqs/a $F/reqs/a)"
: > logs/front.log
echo "backend Connection: close: $(conns $F/close/a $F/close/a $F/close/a)"
saved=$(trace 'saving connection' | wc -l | tr -d ' ' || true)
expect "keepalive_requests ends a connection after 2; Connection: close is never saved" \
    "$(conns $F/reqs/a $F/reqs/a $F/reqs/a)| $saved" "2 1 2 | 0"

step "sticky must come after the balancing method"
t | grep warn
echo "least_conn; sticky: $(hdrs $F/stk/a 'set-cookie' | grep -ci 'set-cookie: srv=')"
echo "sticky; least_conn: $(hdrs $F/stkbad/a 'set-cookie' | grep -ci 'set-cookie: srv=')"
expect "least_conn after sticky replaces it: no cookie" \
    "$(hdrs $F/stk/a 'set-cookie' | grep -ci 'set-cookie: srv=') $(hdrs $F/stkbad/a 'set-cookie' | grep -ci 'set-cookie: srv=')" "1 0"

step "buffered, unbuffered, and X-Accel-Buffering: no"
for p in /buf/big.bin /nobuf/big.bin /xab/xab.bin; do
    : > logs/front.log
    python3 client.py 19180 "$p"
    echo "  temp file warning: $(trace 'buffered to a temporary file' | wc -l | tr -d ' ')," \
        "non buffered reads: $(trace 'process non buffered upstream' | wc -l | awk '{ print ($1 > 0 ? "yes" : "no") }')"
done | tee out/run/buf.txt
expect "only the buffered request spills to a temp file; all three get 4194304 bytes" \
    "$(grep -o 'warning: [0-9]*' out/run/buf.txt | tr '\n' ' ')$(grep -c 'body 4194304 bytes' out/run/buf.txt)" \
    "warning: 1 warning: 0 warning: 0 3"
