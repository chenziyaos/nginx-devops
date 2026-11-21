# dev-06: the life of an HTTP request, seen through the debug log of one worker, plus the phase
# engine read from memory by ph.c (linked against the build's objects by labs/ctest.sh).
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

# trace RE: the debug lines matching RE, without times, pids, connection numbers, pointers
# and the lab path
trace() {
    grep -aE "$1" logs/error.log \
        | sed -E -e 's/^[0-9\/]+ [0-9:]+ \[[a-z]+\] [0-9]+#[0-9]+: //' -e 's/^\*[0-9]+ //' \
            -e 's/ [0-9A-F]{16}( |$)/\1/' -e "s#$LAB/#\$LAB/#g" -e 's/(, client: |, server: | while ).*//'
}

step "the phase engine read from memory"
ctest ph.c "$LAB/" conf/nginx.conf > out/run/ph.txt
base=$(nm out/run/ctest/ph | awk '$3 == "_ngx_http_core_run_phases" { print $1 }')
# name OFFSET: the symbol at ngx_http_core_run_phases + OFFSET
name() {
    local a
    [[ $1 == "+0" ]] && { echo "-"; return; }
    a=$(printf '%016x' $((16#$base + $1)))
    nm out/run/ctest/ph | awk -v a="$a" '$1 == a { sub(/^_/, "", $3); print $3; exit }'
}
while IFS= read -r line; do
    case $line in
        *handler=*) printf '%s %s\n' "${line%% handler=*}" "$(name "${line##*handler=}")" ;;
        *filter=*)  printf '%s=%s\n' "${line%%=*}" "$(name "${line##*=}")" ;;
        *)          echo "$line" ;;
    esac
done < out/run/ph.txt | tee out/run/ph-named.txt
# ngx_http_init_phase_handlers: POST_REWRITE jumps back to FIND_CONFIG (next=2); every handler
# of a phase has the index of the next phase as next; LOG is not in the array
expect "18 entries, post_rewrite goes back to find_config, access handlers jump over post_access" \
    "$(grep -cE '^ *[0-9]+ ' out/run/ph-named.txt) $(awk '$2 == "post_rewrite" { print $3 }' out/run/ph-named.txt) $(awk '$2 == "access" { print $3 }' out/run/ph-named.txt | sort -u)" \
    "18 next=2 next=12"

start
sleep 0.3

step "a request that arrives in three pieces"
python3 client.py split 19120
trace 'http wait request handler|http process request (line|header line)|http request line|http header:|http header done'
# ngx_http_process_request_line returns on NGX_AGAIN and runs again on the next read event
expect "the request line handler runs twice, the header handler twice" \
    "$(trace 'http process request line$' | wc -l | tr -d ' ') $(trace 'http process request header line$' | wc -l | tr -d ' ')" "2 2"

step "header buffers: 1k first, then one 4k large buffer per line"
: > logs/error.log
python3 client.py raw 19120 long-2k
python3 client.py raw 19120 long-5k
trace 'alloc large header buffer|large header (alloc|copy)|too long header line' | sed -E 's/(header line: "X-Long: a{8})a+.*/\1..."/'
# ngx_http_alloc_large_header_buffer: the unparsed part of the 1k buffer (1024 - 30 bytes of
# request line and Host) is copied into a 4k buffer; a line longer than 4k is 494, sent as 400
expect "the 2000-byte line moves to a 4k buffer, the 5000-byte line is 400" \
    "$(trace 'large header copy' | head -1) $(grep -c '"GET /a.txt HTTP/1.1" 400' logs/access.log)" "http large header copy: 994 1"

step "checks while reading headers and after the last one"
: > logs/error.log
for n in many nocolon nohost cl-te; do python3 client.py raw 19120 "$n"; done
trace '\[info\] .*client sent' | sed -E 's/^\[info\] //'
# max_headers (1.29.8+), header line without a colon (rejected since 1.31.9), then
# ngx_http_process_request_header: Host for HTTP/1.1, Content-Length with Transfer-Encoding
expect "all four are 400" "$(tail -4 logs/access.log | awk '{ print $NF }' | tr '\n' ' ')" "400 400 400 400 "

step "rewrite ... last goes back to find_config"
: > logs/error.log
code http://127.0.0.1:19120/r/a.txt
trace 'phase: [0-9]+|using configuration|uri changes|rewritten data' | sed -E 's/, args: "".*//'
expect "after the rewrite the phases continue at find_config (2), then rewrite (3) again" \
    "$(trace 'phase: [0-9]+|using configuration' | tr '\n' '|' | grep -o 'post rewrite phase: 4|using configuration "/static/"|rewrite phase: 3|' | head -1)" \
    'post rewrite phase: 4|using configuration "/static/"|rewrite phase: 3|'

step "ten URI changes at most"
: > logs/error.log
code http://127.0.0.1:19120/loop/a
trace 'uri changes' | tr '\n' ' ' | sed 's/ $//'; echo
trace 'redirection cycle'
# uri_changes starts at NGX_HTTP_MAX_URI_CHANGES + 1 = 11; post_rewrite decrements it and stops at 0
expect "11 rewrites, the 11th is rejected with 500" \
    "$(trace 'uri changes' | wc -l | tr -d ' ') $(tail -1 logs/access.log | awk '{ print $NF }')" "11 500"

step "an internal redirect starts again at server rewrite"
: > logs/error.log
code http://127.0.0.1:19120/missing
trace 'internal redirect|phase: [0-9]+|http finalize request|http request count' | grep -A1 'internal redirect'
trace 'http finalize request|http request count'
# ngx_http_internal_redirect: phase_handler = server_rewrite_index (1), main->count++
expect "error_page restarts at index 1 and holds one more reference" \
    "$(trace 'internal redirect|phase: [0-9]+' | grep -A1 'internal redirect' | tail -1) $(trace 'http request count' | head -1)" \
    "rewrite phase: 1 http request count:2 blk:0"

step "deny ends the request in the access phase"
: > logs/error.log
code http://127.0.0.1:19120/deny
trace 'phase: [0-9]+|access forbidden|http finalize request' | tail -4
expect "the last phase line is access phase: 8, then 403" \
    "$(trace 'phase: [0-9]+' | tail -1) $(tail -1 logs/access.log | awk '{ print $NF }')" "access phase: 8 403"

step "subrequests: SSI include, the postpone filter and the reference count"
: > logs/error.log
get http://127.0.0.1:19120/page.shtml | tr '\n' ' ' | sed 's/ *$//'; echo
# the client connection of the page (the backend connection of /slow has its own number)
main=$(grep -a 'http request line: "GET /page.shtml' logs/error.log | sed -E 's/.*: (\*[0-9]+) .*/\1/')
grep -a "$main " logs/error.log > out/run/page.log
trace() { grep -aE "$1" out/run/page.log | sed -E -e 's/^[0-9\/]+ [0-9:]+ \[[a-z]+\] [0-9]+#[0-9]+: //' -e 's/^\*[0-9]+ //' -e 's/ [0-9A-F]{16}$//'; }
trace 'http subrequest|posted request|http finalize request|wake parent|postpone filter (output|wake)|http upstream connect:|writev|http chunk'
# ngx_http_subrequest: count++ per subrequest; c->data moves to the first one; output of a
# request that is not c->data is kept by the postpone filter until its turn
expect "two subrequests, three references, one writev to the client" \
    "$(trace 'http subrequest' | wc -l | tr -d ' ') $(trace 'http finalize request: 0, "/page.shtml\?" a:0' | sed -E 's/.* (c:[0-9]+)/\1/') $(trace 'writev: 201 of 201' | wc -l | tr -d ' ')" \
    "2 c:3 1"
