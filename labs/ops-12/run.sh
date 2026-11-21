# ops-12: stream proxy, passive checks, UDP sessions, ssl_preread, virtual servers, pass,
# PROXY protocol. Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"

OPENSSL=${OPENSSL:-$( (command -v brew > /dev/null && echo "$(brew --prefix openssl@3)/bin/openssl") || command -v openssl)}
ssl() { "$OPENSSL" "$@"; }

# a throwaway CA and two certificates in out/run/
O=out/run
ssl req -x509 -newkey rsa:2048 -nodes -keyout $O/ca.key -out $O/ca.crt -days 2 -subj /CN=lab-ca 2> /dev/null
issue() {   # issue NAME CN
    ssl req -newkey rsa:2048 -nodes -keyout $O/$1.key -out $O/$1.csr -subj "/CN=$2" 2> /dev/null
    printf 'subjectAltName=DNS:%s\n' "$2" > $O/$1.ext
    ssl x509 -req -in $O/$1.csr -CA $O/ca.crt -CAkey $O/ca.key -CAcreateserial -days 2 -extfile $O/$1.ext -out $O/$1.crt 2> /dev/null
}
issue a a.test
issue b b.test

cl() { python3 "$LAB/client.py" "$@"; }
GET='GET / HTTP/1.0\r\n\r\n'
# slog PORT: stream.log lines of sessions accepted on PORT
slog() { grep -a "^$1 " logs/stream.log || true; }
# wait_log PORT N: wait up to 5 s until PORT has N log lines
wait_log() { local i; for i in $(seq 50); do (( $(slog "$1" | wc -l) >= $2 )) && return 0; sleep 0.1; done; }
# field LINE NAME: the value of NAME=... in a log line
field() { sed -E "s/.* $2=(\[[^]]*\]|[^ ]*).*/\1/" <<< "$1"; }

start

step "a TCP proxy and its log line"
r=$(cl tcp 18240 "$GET")
echo "$r" | sed -E 's/local_port=[0-9]+ //'
wait_log 18240 1
l=$(slog 18240)
echo "$l"
got=$(sed -E 's/.*bytes=([0-9]+).*/\1/' <<< "$r")
expect "bytes_received = upstream_bytes_sent = the 18-byte request; bytes_sent = upstream_bytes_received = what the client got" \
    "$(field "$l" recv) $(field "$l" upsent) $(field "$l" sent) $(field "$l" uprecv)" "18 18 $got $got"

step "failover and the passive check"
for i in 1 2; do cl tcp 18241 "$GET" > /dev/null; wait_log 18241 $i; done
sleep 3.2    # fail_timeout=2s compares whole seconds: now - checked must exceed 2
for i in 3 4 5; do cl tcp 18241 "$GET" > /dev/null; wait_log 18241 $i; done
slog 18241 | sed -E 's/.*up=\[([^]]*)\].*/\1/' | awk '{ print "session " NR ": " $0 }'
errlog 'connect\(\) failed|temporarily disabled' | sed -E 's/\*[0-9]+ //; s/, client: .*//; s/ while connecting to upstream//'
expect "the dead server is skipped for fail_timeout, then the smooth round robin brings it back after two picks of the live one" \
    "$(slog 18241 | sed -E 's/.*up=\[([^]]*)\].*/\1/' | tr '\n' '|')" \
    "127.0.0.1:18259, 127.0.0.1:18250|127.0.0.1:18250|127.0.0.1:18250|127.0.0.1:18250|127.0.0.1:18259, 127.0.0.1:18250|"
expect "two refused connects, each one disables the server" \
    "$(grep -c 'Connection refused' logs/error.log) $(grep -c 'temporarily disabled' logs/error.log)" "2 2"

step "UDP sessions"
cl udp 18242 ping | sed -E 's/local_port=[0-9]+ //'
wait_log 18242 1
echo "proxy_responses 1: $(slog 18242 | wc -l | tr -d ' ') log line right after the reply: $(slog 18242)"
cl udp 18243 ping | sed -E 's/local_port=[0-9]+ //'
sleep 0.5
n1=$(slog 18243 | wc -l | tr -d ' ')
wait_log 18243 1
sleep 0.2
echo "no proxy_responses: $n1 log lines after 0.5 s, $(slog 18243 | wc -l | tr -d ' ') after proxy_timeout 2s: $(slog 18243)"
expect "with proxy_responses the session ends on the reply; without it, at proxy_timeout" \
    "$(slog 18242 | awk '{ print $2, $3 }') | $n1 $(slog 18243 | awk '{ print $2, $3 }')" "UDP 200 | 0 UDP 200"

step "SNI routing with ssl_preread"
for n in a.test b.test; do cl tls 18244 $n $O/ca.crt | sed -E 's/local_port=[0-9]+ //; s/remote_port=[0-9]+/remote_port=<port>/' | tr '\n' ' '; echo; done
cl tcp 18244 "$GET" | sed -E 's/local_port=[0-9]+ //'
expect "a.test and b.test reach the TLS server with their own certificate; plain HTTP goes to the default" \
    "$(cl tls 18244 a.test $O/ca.crt | sed -n 's/^cert=//p') $(cl tls 18244 b.test $O/ca.crt | sed -n 's/^cert=//p') $(cl tcp 18244 "$GET" | sed -E 's/.*first=//')" \
    "a.test b.test HTTP/1.1 200 OK"

step "virtual servers selected by the preread name"
cl tls 18245 a.test $O/ca.crt | sed -E 's/local_port=[0-9]+ //; s/remote_port=[0-9]+/remote_port=<port>/' | tr '\n' ' '; echo
cl tcp 18245 "$GET" | sed -E 's/local_port=[0-9]+ //'
expect "a.test is served by its server{}, anything else by the default one" \
    "$(cl tls 18245 a.test $O/ca.crt | sed -n 's/^cert=//p') $(cl tcp 18245 "$GET" | sed -E 's/.*first=//')" "a.test HTTP/1.1 200 OK"

step "access rules run before the preread name switches the server"
cl tls 18246 a.test $O/ca.crt | sed -E 's/local_port=[0-9]+ //; s/remote_port=[0-9]+/remote_port=<port>/' | tr '\n' ' '; echo
wait_log 18246 1
slog 18246 | awk '{ print $1, $2, $3, $6 }'
expect "deny all in the a.test server{} does not stop a.test: the access phase ran in the default server" \
    "$(slog 18246 | awk '{ print $3 }') $(grep -c 'access forbidden' logs/error.log || true)" "200 0"

step "pass keeps the client's connection, proxy_pass opens a new one"
: > logs/stream.log
for p in 18247 18244; do
    r=$(cl tls $p a.test $O/ca.crt | head -1)
    lp=$(sed -E 's/local_port=([0-9]+).*/\1/' <<< "$r"); rp=$(sed -E 's/.*remote_port=([0-9]+).*/\1/' <<< "$r")
    echo "via $p: backend sees the client's own port: $([[ $lp == "$rp" ]] && echo yes || echo no)"
    res+=("$([[ $lp == "$rp" ]] && echo same || echo other)")
done
sleep 0.2
awk '{ print $1, $2, $3 }' logs/stream.log | sort | uniq -c | awk '{ print $1 "x port " $2 " " $3 " " $4 }'
expect "pass: same port, no log line for 18247; proxy_pass: nginx's port" \
    "${res[*]} $(slog 18247 | wc -l | tr -d ' ')" "same other 0"
cl tcp 18248 > /dev/null
wait_log 18248 1
errlog 'port not found' | sed -E 's/\*[0-9]+ //; s/, client: .*//'
expect "a pass to an unknown address ends with status 200" "$(slog 18248 | awk '{ print $3 }')" "200"

step "PROXY protocol v1 and v2"
for p in 18249 18254; do
    r=$(cl tcp $p)
    lp=$(sed -E 's/local_port=([0-9]+).*/\1/' <<< "$r")
    echo "via $p: $(sed -E 's/.*first=//; s/(remote=127.0.0.1:)[0-9]+/\1<port>/; s/(pp=127.0.0.1:)'"$lp"'/\1<client port>/' <<< "$r")"
done
cl tcp 18253 "$GET" > /dev/null    # the reply is a reset or an EOF, depending on timing
wait_log 18253 3
errlog 'broken header' | sed -E 's/\*[0-9]+ //; s/, client: .*//'
expect "both versions carry the client port; a connection without the header gets 400" \
    "$(for p in 18249 18254; do r=$(cl tcp $p); lp=$(sed -E 's/local_port=([0-9]+).*/\1/' <<< "$r"); grep -q "pp=127.0.0.1:$lp " <<< "$r" && echo carried; done | tr '\n' ' ')$(slog 18253 | awk '$3 == 400' | wc -l | tr -d ' ')" \
    "carried carried 1"

stop
