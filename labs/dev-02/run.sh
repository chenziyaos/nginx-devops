# dev-02: nginx's basic data structures, called from ds.c (linked against the build's
# objects by labs/ctest.sh), plus the server_names hash limit seen through nginx -t.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

ds() { ctest ds.c "$@"; }

step "ngx_str_t"
ds str
expect "16 bytes (a length and a pointer); slices share the bytes, nothing is NUL-terminated" \
    "$(ds str | sed -n '3p')" "ngx_strlow: example.com; the byte after name in the original: ':'"

step "ngx_array_t grows in place, then doubles"
ds array
# ngx_array_push: when full, +1 element in place if the array is the pool's last allocation
# and the block has room, otherwise 2 * nalloc and a copy
expect "2, 2, 3, 4, 5 in place; after another allocation 5 -> 10 with a copy" \
    "$(ds array | awk '{ sub("nalloc=", "", $4); printf "%s ", $4 }')" "2 2 3 4 5 10 10 "

step "ngx_list_t adds parts and never moves elements"
ds list
expect "10 elements in parts of 4: 4 + 4 + 2" \
    "$(ds list | awk '/^part/ { sub("nelts=", "", $3); printf "%s ", $3 }')" "4 4 2 "

step "ngx_queue_t and ngx_queue_sort"
ds queue
expect "a stable merge sort: equal keys keep their insertion order" \
    "$(ds queue | sed -n '1p')" "sorted: 1b 1e 2d 3a 3c"

step "ngx_hash_t: exact names and wildcards"
ds hash example.com www.example.com a.example.com a.b.example.com example.org x.example.org \
    www.example.net EXAMPLE.com > out/run/hash.txt
cat out/run/hash.txt
# the size ngx_hash_init picks, recomputed from its loop: start = nelts / ((bucket - 8) / 16),
# the first size where no bucket holds more than bucket - 8 bytes of elements
want=$(python3 - out/run/hash.txt <<'PY'
import re, sys
names = re.findall(r'^  (\S+) +key_hash', open(sys.argv[1]).read(), re.M)
def key(s):
    h = 0
    for c in s.lower().encode():
        h = (h * 31 + c) % 2**64
    return h
def elt(s):
    return 8 + (len(s) + 2 + 7) // 8 * 8
bucket = 64 - 8
size = max(len(names) // (bucket // 16), 1)
while True:
    used, fits = {}, True
    for n in names:
        b = key(n) % size
        used[b] = used.get(b, 0) + elt(n)
        fits = fits and used[b] <= bucket
    if fits:
        break
    size += 1
print(size)
PY
)
expect "the hash size matches the search in ngx_hash_init" \
    "$(sed -n 's/^exact hash: bucket_size=64, size=//p' out/run/hash.txt)" "$want"
expect "exact first, then *.name (any depth), .name (bare and any depth), name.*; no case folding on lookup" \
    "$(sed -n 's/^find \([^ ]*\) *-> /\1=/p' out/run/hash.txt | tr '\n' ' ')" \
    "example.com=example.com www.example.com=www.example.com a.example.com=*.example.com a.b.example.com=*.example.com example.org=.example.org x.example.org=.example.org www.example.net=www.example.* EXAMPLE.com=not found "

step "server_names_hash_bucket_size limits the length of one name"
for c in name111-single name110 name111; do echo "$c: $(t conf/$c.conf | grep -E 'emerg|successful' | head -1)"; done
# NGX_HASH_ELT_SIZE = 8 + align(len + 2, 8), and a bucket also needs an 8-byte end marker.
# The default bucket is ngx_cacheline_size: hw.cachelinesize on macOS, 128 on this machine,
# so 8 + align(len + 2, 8) + 8 <= 128 gives align(len + 2, 8) <= 112, i.e. len <= 110.
# ngx_http_optimize_servers builds the hash only for an address with more than one server.
expect "alone, any length passes; next to another server, 110 bytes fit a 128-byte bucket and 111 do not" \
    "$(t conf/name111-single.conf | grep -c successful) $(t conf/name110.conf | grep -c successful) $(t conf/name111.conf | grep -c 'increase server_names_hash_bucket_size: 128')" "1 1 1"

step "ngx_rbtree_t"
ds rbtree
expect "sorted in order, equal keys in insertion order, the red-black rules hold" \
    "$(ds rbtree | sed -n '1p') | $(ds rbtree | sed -n '2p' | sed -E 's/, black height.*//')" \
    "in order: 10e 20b 20d 20h 30j 50a 60f 70c 80g 90i | root is black: yes, red nodes with a red child or unequal black heights: 0"

step "the timer tree survives a wrap-around"
ds timer
expect "insert_timer_value compares signed differences" "$(ds timer | sed -n '2p')" "insert_timer_value: min is a (2^64-16)"

step "ngx_radix_tree_t"
ds radix
expect "longest prefix wins; an existing prefix is not replaced" \
    "$(ds radix | sed -E 's/.*(: |-> )//' | tr '\n' '|')" "NGX_BUSY|2|1|no value|2|"

step "where each structure is used"
SRCDIR=$SRC/src
for api in ngx_array_push ngx_list_push ngx_queue_insert_tail ngx_hash_find ngx_rbtree_insert ngx_radix32tree_find; do
    printf '%-24s %3d files\n' "$api" "$(grep -rl "$api(" "$SRCDIR" | wc -l | tr -d ' ')"
done
echo "radix tree users: $(grep -rl 'ngx_radix32tree_find(' "$SRCDIR" | grep -v 'core/ngx_radix_tree' | sed "s#$SRCDIR/##" | sort | tr '\n' ' ')"
expect "the radix tree is used only by the geo modules" \
    "$(grep -rl 'ngx_radix32tree_find(' "$SRCDIR" | grep -v 'core/ngx_radix_tree' | sed "s#$SRCDIR/##" | sort | tr '\n' ' ')" \
    "http/modules/ngx_http_geo_module.c stream/ngx_stream_geo_module.c "
