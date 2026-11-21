# ops-07: load balancing methods and passive health checks.
# Expected values come from the source (see HYPOTHESES.md): the round robin and ip_hash
# sequences are simulated below with the formulas of the C code, not copied from a run.
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:18140

# port PATH: the port of the backend that answered (the backends answer with it)
port() { curl -s "$U$1"; }
# ports N PATH: N requests one after another, the answering ports on one line
ports() { local i out=(); for i in $(seq "$1"); do out+=("$(port "$2")"); done; echo "${out[*]}"; }
# md5hex STRING: what ngx_http_upstream_init_round_robin_sid computes for a server name
md5hex() { python3 -c 'import hashlib, sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())' "$1"; }
# name PORT: A, B, C... for the backend ports, so sequences read like the chapter
name() { sed -e 's/18141/A/g; s/18142/B/g; s/18143/C/g; s/18144/E/g; s/18146/D/g'; }

mkdir -p out/run/files
# limit_rate lets the first second's worth (50 KB) through at once, so the files are larger
head -c 100000 /dev/zero > out/run/files/f.bin
head -c 200000 /dev/zero > out/run/files/slow.bin

start

step "smooth weighted round robin"
# ngx_http_upstream_get_peer: current += effective for all; pick max (first on ties);
# picked -= total
want=$(python3 - <<'PY'
peers = [['A', 5, 0], ['B', 1, 0], ['C', 1, 0]]
out = []
for _ in range(14):
    total, best = 0, None
    for p in peers:
        p[2] += p[1]
        total += p[1]
        if best is None or p[2] > best[2]:
            best = p
    best[2] -= total
    out.append(best[0])
print(' '.join(out))
PY
)
got=$(ports 14 /rr/ | name)
echo "weights A=5 B=1 C=1, 14 requests: $got"
expect "the sequence of the smooth weighted algorithm in ngx_http_upstream_get_peer" "$got" "$want"

step "max_fails and fail_timeout"
: > logs/error.log
first=$(ports 4 /onedead/ | name)
echo "4 requests right away:  $first"
echo "connect() failed lines: $(grep -c 'connect() failed' logs/error.log)"
errlog 'temporarily disabled' | sed -E 's/\*[0-9]+ //; s/, client.*//'
sleep 2.5
after=$(ports 4 /onedead/ | name)
echo "after fail_timeout=2s, 4 more requests: $after, connect() failed lines: $(grep -c 'connect() failed' logs/error.log)"
expect "every request is answered by A; the dead server is tried once, then once more after fail_timeout" \
    "$first $after $(grep -c 'connect() failed' logs/error.log)" "A A A A A A A A 2"

step "a single server is never marked failed"
: > logs/error.log
echo "3 requests: $(seq_codes 3 $U/single/)"
echo "connect() failed lines: $(grep -c 'connect() failed' logs/error.log), no live upstreams: $(grep -c 'no live upstreams' logs/error.log || true)"
expect "with one server every request connects again" \
    "$(grep -c 'connect() failed' logs/error.log) $(grep -c 'no live upstreams' logs/error.log || true)" "3 0"

step "all servers failed, backup, down"
: > logs/error.log
echo "alldead, 2 requests: $(seq_codes 2 $U/alldead/)"
errlog 'connect\(\) failed|no live' | sed -E 's/\*[0-9]+ //; s/ \(61: Connection refused\)//; s/, client.*upstream: "([^"]*)".*/, upstream: \1/; s/, client.*//'
echo "withbak:  $(ports 3 /withbak/ | name)"
echo "withdown: $(ports 3 /withdown/ | name)"
expect "the second request finds no live peer; backup answers when the group is dead; down is skipped" \
    "$(grep -c 'no live upstreams' logs/error.log) $(ports 3 /withbak/ | name) $(ports 3 /withdown/ | name)" \
    "1 D D D A A A"

step "what proxy_next_upstream counts"
: > logs/error.log
: > logs/access.log
echo "default (error timeout), 4 GETs:   $(seq_codes 4 $U/flaky/)"
echo "error timeout http_500, 4 GETs:    $(seq_codes 4 $U/flaky2/)"
echo "error timeout http_500, 2 POSTs:   $(seq_codes 2 $U/flaky3/ -X POST -d x)"
sleep 0.2
grep '^/flaky2/\|^/flaky3/' logs/access.log | sed -e 's/127.0.0.1://g' | name
errlog 'temporarily disabled' | sed -E 's/\*[0-9]+ //; s/, client.*//'
expect "500 is passed on by default; with http_500 GETs move on, a POST that was sent does not" \
    "$(seq_codes 4 $U/flaky/) | $(grep -c '^/flaky2/ 200' logs/access.log) | $(grep '^/flaky3/' logs/access.log | awk '{ print $2 }' | tr '\n' ' ')" \
    "200 500 200 500 | 4 | 200 500 "

step "hash and hash consistent when a server is removed"
moved() {
    local k a b n=0 kept=0
    for k in $(seq 60); do
        a=$(port "/$1/?k=$k"); b=$(port "/$2/?k=$k")
        [[ $a == 18143 ]] && continue
        kept=$((kept + 1))
        [[ $a != "$b" ]] && n=$((n + 1))
    done
    echo "$n of $kept"
}
c=$(moved ch3 ch2); p=$(moved ph3 ph2)
echo "keys not on C that moved, consistent: $c"
echo "keys not on C that moved, plain hash: $p"
expect "consistent hashing moves only the removed server's keys; plain hash moves others too" \
    "${c%% *} $([[ ${p%% *} -gt 0 ]] && echo some)" "0 some"

step "ip_hash"
# ngx_http_upstream_get_ip_hash_peer: hash = 89; for the first 3 bytes of the IPv4 address
# hash = (hash * 113 + byte) % 6271; peer = hash % total_weight
want=$(python3 - <<'PY'
h = 89
for b in (127, 0, 0):
    h = (h * 113 + b) % 6271
print('ABC'[h % 3], h)
PY
)
got=$(ports 5 /iph/ | name)
echo "hash for 127.0.0.x: ${want#* }, peer index ${want#* } % 3 = $(( ${want#* } % 3 ))"
echo "5 requests from 127.0.0.1: $got"
expect "every request goes to the peer the formula picks" "$got" "$(for i in 1 2 3 4 5; do printf '%s ' "${want%% *}"; done | sed 's/ $//')"

step "least_conn"
for up in rr2 lc; do
    curl -s -o /dev/null -D out/run/slow.h "$U/$up/slow.bin" &
    for i in $(seq 50); do [[ -s out/run/slow.h ]] && break; sleep 0.05; done
    slow=$(tr -d '\r' < out/run/slow.h | sed -n 's/^X-Port: //p' | name)
    echo "$up: slow download on $slow, 4 quick requests: $(ports 4 /$up/ | name)"
    wait
    rm -f out/run/slow.h
done
curl -s -o /dev/null -D out/run/slow.h "$U/lc/slow.bin" &
for i in $(seq 50); do [[ -s out/run/slow.h ]] && break; sleep 0.05; done
slow=$(tr -d '\r' < out/run/slow.h | sed -n 's/^X-Port: //p' | name)
quick=$(ports 4 /lc/ | name)
wait
other=$([[ $slow == A ]] && echo E || echo A)
expect "least_conn sends every quick request to the server without the slow one" "$quick" "$other $other $other $other"

step "least_time last_byte"
for up in rr3 lt; do
    : > logs/access.log
    for i in $(seq 10); do curl -s -o /dev/null "$U/$up/f.bin"; done
    sleep 0.2
    echo "$up: 10 requests for a 100 KB file, E (50 KB/s) answered $(grep -c ':18144 ' logs/access.log || true)"
done
expect "after E took about 1 s once, least_time keeps sending to A" "$(grep -c ':18144 ' logs/access.log || true)" "1"

step "sticky cookie"
c1=$(curl -s -D - -o /dev/null $U/st/ | tr -d '\r' | sed -n 's/^Set-Cookie: //p')
echo "first response: Set-Cookie: $c1"
v=${c1#srv=}; v=${v%%;*}
for p in 18141 18142 18143; do
    printf '  md5("127.0.0.1:%s") = %s\n' "$p" "$(md5hex "127.0.0.1:$p")"
done
echo "5 requests with that cookie: $(for i in 1 2 3 4 5; do curl -s -b "srv=$v" $U/st/; done | tr '\n' ' ' | name)"
echo "route=: $(curl -s -D - -o /dev/null $U/str/ | tr -d '\r' | sed -n 's/^Set-Cookie: //p'), $(curl -s -D - -o /dev/null $U/str/ | tr -d '\r' | sed -n 's/^Set-Cookie: //p')"
target=$(for p in 18141 18142 18143; do if [[ $(md5hex "127.0.0.1:$p") == "$v" ]]; then echo "$p"; fi; done | name)
expect "the cookie is the MD5 of the server address, and requests carrying it stay there" \
    "$(for i in 1 2 3 4 5; do curl -s -b "srv=$v" $U/st/; done | tr '\n' ' ' | name)" "$target $target $target $target $target "

stop

step "resolve needs a zone"
t conf/resolve-nozone.conf | head -1
expect "server ... resolve is rejected unless the upstream has a zone" \
    "$(t conf/resolve-nozone.conf | head -1 | grep -c 'to be in shared memory')" "1"
