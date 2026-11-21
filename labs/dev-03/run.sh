# dev-03: the pool, buffer, slab and shmtx APIs called from mem.c (linked against the build's
# objects by labs/ctest.sh), then the pools of one request and the shared zone rules as nginx
# itself shows them. Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

mem() { ctest mem.c "$@"; }

# pool_log PORT: the allocation lines of one request on PORT, addresses renamed A, B, C...
# in order of first appearance
pool_log() {
    : > logs/error.log
    curl -s -o /dev/null -H 'User-Agent: lab' "http://127.0.0.1:$1/"
    sleep 0.3
    # the connection pool is created before the connection has a log of its own, so its line
    # has no *N
    grep -aE '\*[0-9]+ (malloc|posix_memalign|free|accept|set http keepalive|close http)|posix_memalign: [0-9A-F]+:512 ' logs/error.log \
        | sed -E 's/^.*\*[0-9]+ //; s/^.*#[0-9]+: //; s/accept: 127.0.0.1:[0-9]+ fd:[0-9]+/accept/; s/close http connection: [0-9]+/close http connection/' \
        | awk '{ while (match($0, /[0-9A-F]{16}/)) { a = substr($0, RSTART, 16)
                     if (!(a in n)) n[a] = (a ~ /^0+$/ ? "NULL" : sprintf("%c", 65 + k++))
                     $0 = substr($0, 1, RSTART - 1) n[a] substr($0, RSTART + 16) } print }'
}

step "ngx_pool_t: small allocations, a new block, large allocations"
mem pool
# sizeof(ngx_pool_t) is 80 on 64-bit, so max = 1024 - 80. NGX_ALIGNMENT is sizeof(uintptr_t)
# by default, but auto/os/conf defines 16 for aarch64/arm64 (this machine)
expect "palloc aligns to NGX_ALIGNMENT (16 here), pnalloc does not; a new block keeps only ngx_pool_data_t (32 bytes); above max goes to malloc" \
    "$(mem pool | sed -n '3p;5p;6p' | tr '\n' '|')" \
    "ngx_palloc(1) at +80, ngx_palloc(1) at +96, ngx_pnalloc(1) at +97, ngx_pnalloc(1) at +98|ngx_palloc(944) (= max): blocks=2, at +32 in the new block, from the heap: no|ngx_palloc(945) (> max): blocks=2, from the heap: yes|"

step "pool->current moves past a block that failed more than 4 times"
mem current
# ngx_palloc_block: "if (p->d.failed++ > 4) pool->current = p->d.next" for every block from
# current to the tail. Block 0 fails once per new block from the 3rd allocation on.
expect "current leaves block 0 at the 8th 600-byte allocation, then moves one block per allocation" \
    "$(mem current | awk '{ print $5 }' | tr '\n' ' ')" "0, 0, 0, 0, 0, 0, 0, 1, 2, 3, "

step "large allocations: ngx_pfree only helps near the head of the list"
mem large
expect "a freed slot is reused only within the first 5 list nodes (n++ > 3)" \
    "$(mem large | grep -oE '[0-9]+ (list )?nodes' | awk '{ print $1 }' | tr '\n' ' ')" "6 7 7 "

step "cleanup handlers run in reverse order"
mem cleanup
expect "LIFO" "$(mem cleanup | sed -n 's/^cleanup //p' | tr '\n' ' ')" "c b a "

step "ngx_buf_t and ngx_chain_t"
mem chain
expect "update_chains frees foreign links, recycles consumed buffers of its tag, stops at the first unsent one" \
    "$(mem chain | sed -n '5,6p' | tr '\n' '|')" "after ngx_chain_update_chains free: a|busy: b c|"

step "ngx_slab_pool_t on a 1 MB zone"
mem slab 2>&1 | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /'
# the page count ngx_slab_init computes, recomputed: slots and stats come first, then one
# ngx_slab_page_t per page, then the pages from the next page boundary
want=$(python3 - "$(getconf PAGESIZE)" <<'PY'
import sys
page = int(sys.argv[1]); shift = page.bit_length() - 1
zone, pool_hdr, page_t, stat_t = 1 << 20, 144, 24, 32
n = shift - 3
size = zone - pool_hdr - n * (page_t + stat_t)
pages = size // (page + page_t)
used = pool_hdr + n * (page_t + stat_t) + pages * page_t
start = (used + page - 1) // page * page
pages -= max(0, pages - (zone - start) // page)
print("slots=%d, pages=%d, first page at +%d" % (n, pages, start))
PY
)
expect "the page count matches ngx_slab_init" "$(mem slab 2>/dev/null | sed -n '1s/.*, slots/slots/p')" "$want"
# ngx_slab_sizes_init: exact size = pagesize / 64 (one bitmap word in page->slab), max = pagesize / 2
expect "small below pagesize/64, exact at pagesize/64, big up to pagesize/2, whole pages above" \
    "$(mem slab 2>/dev/null | awk '/^alloc/ { printf "%s=%s ", $2, $4 }')" \
    "1=small 8=small 9=small 100=small 128=small 129=exact 256=exact 257=big 8192=big 8193=pages 40000=pages "

step "ngx_shmtx_t: the lock word holds the owner's pid"
mem shmtx
expect "no lost increments; a dead owner's lock is released only by its own pid" \
    "$(mem shmtx | sed -n '2p;4p' | tr '\n' '|')" \
    "4 processes x 100000 locked increments: 400000|ngx_shmtx_force_unlock(other pid): 0, ngx_shmtx_force_unlock(child pid): 1, trylock: 1|"

step "the pools of one request"
start
pool_log 19060
# connection pool: connection_pool_size = 64 * sizeof(void *) = 512, so the 1k header buffer is
# a large allocation; request pool: request_pool_size 4096
expect "a 512-byte connection pool, the 1024-byte header buffer from malloc, a 4096-byte request pool" \
    "$(pool_log 19060 | grep -E 'malloc|memalign' | sed -E 's/: [A-Z]+:/ /' | tr '\n' '|')" \
    "posix_memalign 512 @16|malloc 1024|posix_memalign 4096 @16|posix_memalign 4096 @16|"
echo "with request_pool_size 16k:"
pool_log 19061
expect "with request_pool_size 16k the request needs one block" \
    "$(pool_log 19061 | grep -c 'posix_memalign: [A-Z]*:16384')" "1"
stop

step "shared zones are matched by name, then by owner and size"
for c in zone-tag zone-size zone-size2 zone-missing; do echo "$c: $(t conf/$c.conf | grep -E 'emerg|successful' | head -1)"; done
expect "a name has one owner and one size; a zone used before its declaration is fine, a zone never declared is not" \
    "$(for c in zone-tag zone-size zone-size2 zone-missing; do t conf/$c.conf | grep -cE 'different use|successful|conflicts with already declared size|zero size shared memory zone'; done | tr '\n' ' ')" \
    "1 1 1 1 "

step "where the APIs are used"
SRCDIR=$SRC/src
echo "files calling ngx_chain_update_chains: $(grep -rl 'ngx_chain_update_chains(' "$SRCDIR" | wc -l | tr -d ' ')"
echo "calls of ngx_pool_cleanup_add: $(grep -rn 'ngx_pool_cleanup_add(' "$SRCDIR" | wc -l | tr -d ' ')"
echo "modules adding shared zones: $(grep -rl 'ngx_shared_memory_add(' "$SRCDIR" | grep -v core/ngx_cycle | sed "s#$SRCDIR/##; s#.*/##; s#\.c##" | sort | tr '\n' ' ')"
expect "limit_req and limit_conn, the caches, the SSL session caches and the upstream zones use shared memory" \
    "$(grep -rl 'ngx_shared_memory_add(' "$SRCDIR" | grep -v core/ngx_cycle | wc -l | tr -d ' ')" "14"
