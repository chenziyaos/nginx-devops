# ops-10: proxy cache: key and file layout, status sequence, freshness rules, min_uses,
# background update, cache lock, stale on error, revalidation, inactive.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:18200
W=out/run/www
mkdir -p $W/b
head -c 3000 /dev/zero > $W/b/slowa
head -c 3000 /dev/zero > $W/b/slown
echo flag > $W/flag.txt
echo file > $W/file.txt

# xc PATH [curl args...]: the X-Cache header (= $upstream_cache_status) of one request
xc() { local p=$1; shift; curl -s -o /dev/null -D - "$@" "$U$p" | tr -d '\r' | sed -n 's/^X-Cache: //p'; }
# xcs N PATH: N requests one after another, their X-Cache values on one line
xcs() { local i out=(); for i in $(seq "$1"); do out+=("$(xc "$2")"); done; echo "${out[*]}"; }
# hits URI_PREFIX: how many requests the backend saw for it
hits() { grep -c " $1" logs/backend.log || true; }
# md5hex STRING
md5hex() { python3 -c 'import hashlib, sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())' "$1"; }
# cpath KEY: where levels=1:2 puts the file for KEY (ngx_create_hashed_filename)
cpath() { local m; m=$(md5hex "$1"); echo "out/run/cache/${m:31:1}/${m:29:2}/$m"; }
# ttl FILE: valid_sec - date from the binary header of a cache file (64-bit layout:
# version, valid_sec, updating_sec, error_sec, last_modified, date, all 8 bytes)
ttl() {
    python3 - "$1" <<'PY'
import struct, sys
h = open(sys.argv[1], 'rb').read(48)
version, valid, _, _, _, date = struct.unpack('<Qqqqqq', h)
print('version=%d valid_sec-date=%d' % (version, valid - date))
PY
}

start

step "the cache key and the file"
# ngx_http_proxy_create_key without proxy_cache_key: scheme://host:port + the URI sent upstream
key="http://127.0.0.1:18201/b/plain?x=1"
curl -s -o /dev/null "$U/b/plain?x=1"
f=$(cpath "$key")
echo "key:  $key"
echo "md5:  $(md5hex "$key")"
echo "file: $f"
echo "header: $(ttl "$f"), $(grep -a -o 'KEY: .*' "$f")"
expect "the file is named by the MD5 of the key, directories taken from the end of the name" \
    "$(ls "$f" > /dev/null && echo exists) $(grep -a -c "^KEY: $key\$" "$f")" "exists 1"

step "the default key is the URI sent to the backend"
echo "/k1/k: $(xc /k1/k), /k2/k: $(xc /k2/k), /k3/k (proxy_cache_key \$scheme\$proxy_host\$request_uri): $(xc /k3/k)"
keys() { grep -a -h -o -r 'KEY: .*' out/run/cache | grep -E 'plaink|/k3/k' | sort; }
keys
expect "locations that proxy to the same URI share an entry; the documented key keeps them apart" \
    "$(xc /k2/k) $(keys | tr '\n' ' ')" "HIT KEY: http127.0.0.1:18201/k3/k KEY: http://127.0.0.1:18201/b/plaink "

step "MISS, HIT, EXPIRED"
s1=$(xcs 2 /seq/a)
sleep 3.1
s2=$(xcs 2 /seq/a)
echo "proxy_cache_valid 200 2s: $s1, after 3.1 s: $s2; backend requests: $(hits /b/plaina)"
expect "an expired entry goes to the backend once and is stored again" "$s1 $s2 $(hits /b/plaina)" "MISS HIT EXPIRED HIT 2"

step "which header decides the lifetime"
printf '%-9s %-22s %-10s %s\n' backend headers 2nd-request stored
for b in plain:none cc60:max-age=60 smax:max-age=60,s-maxage=90 xae:X-Accel-Expires=30,max-age=60 \
         exppast:Expires=past,max-age=60 private:private,max-age=60 age0:max-age=0 \
         xae0:X-Accel-Expires=0,max-age=60 cookie:Set-Cookie; do
    n=${b%%:*}
    curl -s -o /dev/null "$U/b/$n"
    second=$(xc "/b/$n")
    f=$(cpath "http://127.0.0.1:18201/b/$n")
    if [[ -f $f ]]; then stored=$(ttl "$f" | sed 's/.* //'); else stored="not stored"; fi
    printf '%-9s %-22s %-10s %s\n' "$n" "${b#*:}" "$second" "$stored"
done
# X-Accel-Expires > s-maxage > max-age > proxy_cache_valid (3s here)
expect "X-Accel-Expires, then s-maxage, then max-age, then proxy_cache_valid; private, 0 and Set-Cookie are not stored" \
    "$(for n in plain cc60 smax xae exppast; do ttl "$(cpath "http://127.0.0.1:18201/b/$n")" | sed 's/.*=//'; done | tr '\n' ' ')| $(for n in private age0 xae0 cookie; do [[ -f $(cpath "http://127.0.0.1:18201/b/$n") ]] && echo stored || echo none; done | tr '\n' ' ')" \
    "3 60 90 30 60 | none none none none "

step "HEAD is cached as GET"
echo "HEAD: $(xc /b/plain?h -I), then GET: $(xc /b/plain?h), body: $(curl -s "$U/b/plain?h" | wc -c | tr -d ' ') bytes"
expect "the HEAD request went to the backend as a GET and stored the full response" \
    "$(grep -c '^GET /b/plain?h ' logs/backend.log || true) $(grep -c '^HEAD ' logs/backend.log || true)" "1 0"

step "proxy_cache_min_uses 2"
s=$(xcs 3 /uses/u)
echo "3 requests: $s; backend requests: $(hits /b/plainu)"
expect "the first use only counts, the second stores, the third hits" "$s" "MISS MISS HIT"

step "use_stale updating with background_update"
first=$(curl -s $U/bg/g)
echo "$(xc /bg/g) after the first request"
sleep 6.1
stale_body=$(curl -s -D out/run/h.txt $U/bg/g)
echo "after 6.1 s: $(tr -d '\r' < out/run/h.txt | sed -n 's/^X-Cache: //p'), same body as the first: $([[ $stale_body == "$first" ]] && echo yes || echo no)"
sleep 0.3
new_body=$(curl -s -D out/run/h.txt $U/bg/g)
echo "next request: $(tr -d '\r' < out/run/h.txt | sed -n 's/^X-Cache: //p'), body changed: $([[ $new_body != "$first" ]] && echo yes || echo no)"
expect "the expired entry is sent at once and refreshed by a background subrequest" \
    "$([[ $stale_body == "$first" ]] && echo old) $([[ $new_body != "$first" ]] && echo new)" "old new"

step "proxy_cache_lock"
n=()
for p in /lock/a /nolock/n; do
    b=/b/slow${p##*/}
    before=$(hits $b)
    for i in 1 2 3 4 5; do xc $p & done > out/run/lock.txt
    wait
    n+=($(( $(hits $b) - before )))
    echo "$p, 5 at once: $(sort out/run/lock.txt | uniq -c | awk '{ print $1 "x " $2 }' | tr '\n' ' ')backend requests: ${n[${#n[@]}-1]}"
done
expect "with the lock one request goes to the backend and the others wait for the file" "${n[*]}" "1 5"

step "use_stale error"
curl -s -o /dev/null $U/err/a; curl -s -o /dev/null $U/err2/e
sleep 3.1
rm $W/flag.txt
echo "backend now answers $(code http://127.0.0.1:18201/b/toggle)"
echo "use_stale error http_500: $(code $U/err/a) $(xc /err/a)"
echo "no use_stale:             $(code $U/err2/e) $(xc /err2/e)"
expect "the old copy is sent as STALE when the backend fails; without use_stale the 500 goes through" \
    "$(xc /err/a) $(code $U/err2/e)" "STALE 500"

step "proxy_cache_revalidate"
curl -s -o /dev/null $U/rv/a
sleep 3.1
echo "after expiry: $(xc /rv/a), then $(xc /rv/a)"
echo "backend log: $(grep ' /b/filea' logs/backend.log | awk '{ print $3 }' | tr '\n' ' ')"
expect "the backend answers the conditional request with 304, the entry is renewed" \
    "$(grep ' /b/filea' logs/backend.log | awk '{ print $3 }' | tr '\n' ' ')" "200 304 "

step "proxy_cache_bypass"
b1=$(curl -s -D out/run/h.txt $U/byp/y)
echo "first: $(tr -d '\r' < out/run/h.txt | sed -n 's/^X-Cache: //p')"
b2=$(curl -s -D out/run/h.txt -H 'X-Refresh: 1' $U/byp/y)
echo "with X-Refresh: 1: $(tr -d '\r' < out/run/h.txt | sed -n 's/^X-Cache: //p'), new body: $([[ $b2 != "$b1" ]] && echo yes || echo no)"
b3=$(curl -s -D out/run/h.txt -H 'X-Refresh: 0' $U/byp/y)
echo "with X-Refresh: 0: $(tr -d '\r' < out/run/h.txt | sed -n 's/^X-Cache: //p'), same body as the bypassed one: $([[ $b3 == "$b2" ]] && echo yes || echo no)"
expect "a value other than empty or 0 skips the lookup, and the fresh response replaces the entry" \
    "$(xc /byp/y -H 'X-Refresh: yes') $([[ $b3 == "$b2" ]] && echo replaced)" "BYPASS replaced"

step "inactive=2s"
curl -s -o /dev/null $U/inact/i
fi=$(find out/run/cache-i -type f | head -1)
echo "stored: $([[ -f $fi ]] && echo yes), valid for: $(ttl "$fi" | sed 's/.*=//') s"
# ngx_http_file_cache_expire sleeps at most 10 s between runs, so the file goes away
# between inactive and inactive + 10 s after the last access
t0=$(date +%s)
for i in $(seq 30); do [[ -f $fi ]] || break; sleep 0.5; done
dt=$(( $(date +%s) - t0 ))
echo "deleted without a request: $([[ -f $fi ]] && echo no || echo yes), within 2..12 s: $([[ $dt -ge 1 && $dt -le 13 ]] && echo yes || echo "no ($dt s)")"
expect "the cache manager removes entries not used for inactive, even if they are still valid" \
    "$([[ -f $fi ]] && echo kept || echo deleted) $(xc /inact/i)" "deleted MISS"

stop
