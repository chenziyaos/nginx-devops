# ops-06: what proxy_pass sends to the backend. The backend (18120) is a server in the same
# nginx that echoes the request line, headers and connection counters it received.
# Expected values come from the source (see HYPOTHESES.md), not from a previous run.
. "$(dirname "$0")/../lib.sh"

F=http://127.0.0.1:18121

# uri PATH...: "client URI -> URI the backend saw"
uri() {
    local p
    for p in "$@"; do
        printf '%-12s -> %s\n' "$p" "$(curl -s --path-as-is "$F$p" | sed 's/^uri=//')"
    done
}

# conns PATH...: protocol and request number on the backend connection, and whether the
# connection is the same one as for the previous request ("reused") or a new one
conns() {
    local p line c prev=""
    for p in "$@"; do
        line=$(curl -s "$F$p")
        c=$(sed -E 's/.*conn=([0-9]+).*/\1/' <<< "$line")
        printf '%-12s %s %s\n' "$p" "$(sed -E 's/^proto=([^ ]+) .* (req=[0-9]+)$/\1 \2/' <<< "$line")" \
            "$([[ $c == "$prev" ]] && echo reused || echo new)"
        prev=$c
    done
}

# drop the parts of error.log lines that differ between runs and systems
norm() { sed -E 's/\*[0-9]+ //; s/kevent\(\) reported that //; s/\(([0-9]+): [^)]*\)/(errno)/; s/, client:.*//'; }

start conf/nginx.conf

step "proxy_pass with and without a URI part"
uri '/a/x?q=1' '/a/x%2Fy' '/a//x' '/b/x?q=1' '/b/x%2Fy' '/b/a%20b' '/b//x' '/b/../b/x' \
    '/c0x' '/c0/x' '/d/x' '/re/x' '/rw/x?q=1' | tee out/run/uri.txt
expect "no URI part: the raw request URI; URI part: the location prefix is replaced in the normalized URI" \
    "$(sed -E 's/.* -> //' out/run/uri.txt | tr '\n' '|')" \
    '/a/x?q=1|/a/x%2Fy|/a//x|/new/x?q=1|/new/x/y|/new/a%20b|/new/x|/new/x|/newx|/new/x|/x|/re/x|/new/x?q=1|'

step "a URI part in a regex location"
t conf/bad-regex.conf | tee out/run/t.txt
expect_match "nginx -t rejects it" "$(cat out/run/t.txt)" 'cannot have URI part in location given by regular expression'

step "request headers the backend receives"
curl -s $F/h/x -H 'Connection: keep-alive, Upgrade' -H 'Upgrade: websocket' -H 'TE: trailers' \
    -H 'X-A: from-client' | tee out/run/h.txt
expect "Host is \$proxy_host; Connection, Upgrade and TE are dropped; other headers pass" \
    "$(cat out/run/h.txt)" \
    'host=[127.0.0.1:18120] connection=[] upgrade=[] te=[] x-a=[from-client] x-b=[from-server] xff=[]'
for p in h-up h-loc h-host h-empty h-xff h-ws; do
    printf '%-9s %s\n' "/$p/" "$(curl -s "$F/$p/" -H 'Host: front.test' -H 'X-A: c' \
        -H 'X-Forwarded-For: 203.0.113.7' -H 'Upgrade: websocket')"
done | tee out/run/h.txt
expect "upstream name as Host; a location-level proxy_set_header drops the server-level X-B" \
    "$(awk '{ print $2, $7 }' out/run/h.txt | tr '\n' '|')" \
    'host=[be] x-b=[from-server]|host=[127.0.0.1:18120] x-b=[]|host=[front.test] x-b=[]|host=[127.0.0.1:18120] x-b=[]|host=[127.0.0.1:18120] x-b=[]|host=[127.0.0.1:18120] x-b=[]|'
expect "proxy_add_x_forwarded_for appends the client address" \
    "$(grep -o 'xff=\[[^]]*\]' out/run/h.txt | sed -n 5p)" 'xff=[203.0.113.7, 127.0.0.1]'
ws=$(curl -s "$F/h-ws/"); echo "/h-ws/ without Upgrade: $ws"
expect "Upgrade/Connection set explicitly reach the backend, and only when the client asked" \
    "$(grep -o 'connection=[^ ]* upgrade=[^ ]*' out/run/h.txt | sed -n 6p) / $(grep -o 'connection=[^ ]* upgrade=[^ ]*' <<< "$ws")" \
    'connection=[upgrade] upgrade=[websocket] / connection=[] upgrade=[]'

step "connections to the backend"
conns /k-implicit/ /k-implicit/ /k-implicit/ | tee out/run/k.txt
conns /k-up/ /k-up/ /k-up/ /k-up2/ | tee -a out/run/k.txt
conns /k-sh1/ /k-sh2/ | tee -a out/run/k.txt
conns /k-10/ /k-10/ /k-off/ /k-off/ | tee -a out/run/k.txt
conns /k-h2/ /k-h2/ /k-h2/ | tee -a out/run/k.txt
expect "keepalive by default only for upstream{} blocks, per location with \"local\"" \
    "$(awk '{ print $3, $4 }' out/run/k.txt | sed -n '1,9p' | tr '\n' '|')" \
    'req=1 new|req=1 new|req=1 new|req=1 new|req=2 reused|req=3 reused|req=1 new|req=1 new|req=2 reused|'
expect "HTTP/1.0 and keepalive 0 never reuse; HTTP/2 reuses one connection" \
    "$(awk '{ print $2, $3, $4 }' out/run/k.txt | sed -n '10,16p' | tr '\n' '|')" \
    'HTTP/1.0 req=1 new|HTTP/1.0 req=1 new|HTTP/1.1 req=1 new|HTTP/1.1 req=1 new|HTTP/2.0 req=1 new|HTTP/2.0 req=2 reused|HTTP/2.0 req=3 reused|'

step "502: nothing listens on the backend port"
dead=$(code $F/dead/); echo "/dead/ status: $dead"
errlog 'connect\(\) failed' | norm
expect "connection refused is 502" "$dead" "502"

step "504: the backend is slower than proxy_read_timeout"
first=$(code $F/slow.txt); second=$(code $F/slow.txt); echo "/slow.txt: $first then $second"
errlog 'upstream timed out' | norm
expect "the second request waits on the backend's limit_req, the proxy gives up after 300ms" \
    "$first $second" "200 504"

step "the next server after a failure"
code $F/retry/ > /dev/null; code $F/retry/ > /dev/null
grep '^/retry/' logs/access.log | tee out/run/retry.txt
expect "a refused connection is retried on the next server, which then is skipped for a while" \
    "$(tr '\n' '|' < out/run/retry.txt)" \
    '/retry/ 200 [127.0.0.1:18139, 127.0.0.1:18120] [502, 200]|/retry/ 200 [127.0.0.1:18120] [200]|'

step "buffering: a 32 MB response to a client reading 8 MB/s"
mkdir -p out/run/big
head -c 33554432 /dev/zero > out/run/big/f.bin
curl -s -o /dev/null --limit-rate 8M $F/big/f.bin
curl -s -o /dev/null --limit-rate 8M $F/big-off/f.bin
awk '{ printf "%-16s request_time >= 2: %s, upstream done before half of it: %s\n", $1,
       ($3 >= 2 ? "yes" : "no"), ($4 < $3 / 2 ? "yes" : "no") }' logs/timing.log | tee out/run/buf.txt
errlog 'buffered to a temporary file' | norm | sed -E 's#file /[^ ]*/labs/ops-06/#file $LAB/#'
expect "buffering on frees the backend early, off ties it to the client" \
    "$(awk '{ print $NF }' out/run/buf.txt | tr '\n' ' ')" "yes no "

step "realip"
R=http://127.0.0.1:18122
R2=http://127.0.0.1:18125
{
    echo "18122 /     203.0.113.7               -> $(curl -s $R/ -H 'X-Forwarded-For: 203.0.113.7')"
    echo "18122 /     203.0.113.7, 10.0.0.2     -> $(curl -s $R/ -H 'X-Forwarded-For: 203.0.113.7, 10.0.0.2')"
    echo "18122 /rec/ 203.0.113.7, 10.0.0.2     -> $(curl -s $R/rec/ -H 'X-Forwarded-For: 203.0.113.7, 10.0.0.2')"
    echo "18125 /     203.0.113.7, 10.0.0.2     -> $(curl -s $R2/ -H 'X-Forwarded-For: 203.0.113.7, 10.0.0.2')"
    echo "18125 /     203.0.113.7, 198.51.100.9 -> $(curl -s $R2/ -H 'X-Forwarded-For: 203.0.113.7, 198.51.100.9')"
} | tee out/run/rip.txt
expect "the last address without recursion, the last untrusted one with it; location-level recursion is too late" \
    "$(sed -E 's/.*remote_addr=([^ ]+) .*/\1/' out/run/rip.txt | tr '\n' ' ')" \
    "203.0.113.7 10.0.0.2 10.0.0.2 203.0.113.7 198.51.100.9 "

step "CONNECT tunnel"
via() { { curl -s -p -x "http://127.0.0.1:$1" -w "[CONNECT %{http_connect}]" "$2" || true; } | tr -d "\n"; echo; }
echo "via 18123 to 18120: $(via 18123 http://127.0.0.1:18120/conn/ | sed -E 's/conn=[0-9]+ //')"
echo "via 18123 to 18121: $(via 18123 http://127.0.0.1:18121/a/)"
echo "via 18121 to 18120: $(via 18121 http://127.0.0.1:18120/conn/)"
tunnel=$(cat logs/tunnel.log); echo "$tunnel"
errlog 'CONNECT' | norm
expect "tunnel_pass answers CONNECT with 200, the map limits targets, other servers answer 405" \
    "$(tr '\n' '|' <<< "$tunnel") $(errlog 'client sent CONNECT method' | wc -l | tr -d ' ')" \
    'CONNECT 127.0.0.1:18120 HTTP/1.1 200|CONNECT 127.0.0.1:18121 HTTP/1.1 403| 1'

stop
