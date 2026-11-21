# dev-07: the rewrite module's code arrays (dumped by rw.c, linked against the build's objects
# by labs/ctest.sh) and how they run, seen through rewrite_log and the debug log.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

# notices: the rewrite_log lines, without times, pids and the client part
notices() {
    grep -aE '\[notice\] .*\*[0-9]+ ' logs/error.log | sed -E 's/^.*\[notice\] [0-9]+#[0-9]+: \*[0-9]+ //; s/, client: .*//'
}
# script: the script engine's debug lines (one value per line, the "\n" of return texts dropped)
script() {
    grep -aE 'http script|matches|does not match' logs/error.log \
        | sed -E 's/^[0-9\/]+ [0-9:]+ \[[a-z]+\] [0-9]+#[0-9]+: \*[0-9]+ //; s/, client: .*//' \
        | grep -v '^http script copy: "$'
}
req() { printf '%s -> ' "$1"; curl -s -o out/run/body -w '%{http_code} ' "${@:2}" "http://127.0.0.1:19140$1"; head -1 out/run/body; }

step "the code arrays built at configuration time"
ctest rw.c "$LAB/" conf/nginx.conf server /chain/ /brk/ /args/ /noargs/ /set/ | tee out/run/codes.txt
# ngx_http_rewrite: "last" and "break" add a stop (NULL) after regex_end; the if body is
# compiled into the same array, "next" jumps over it
expect "last and break end in a stop, the third rewrite of /chain/ is after it" \
    "$(awk '/^\/chain\//{f=1} /^\/brk\//{f=0} f && /stop/ {print $1}' out/run/codes.txt | tr '\n' ' ')" "256 376 "

start
sleep 0.3

step "rewrite flags: none, last, break, redirect"
req /old/a
req /chain/a
req /brk/a.txt
req /redir/a
notices | grep -v 'set/'
# no flag: the next rewrite directive still runs; last: the location is searched again;
# break: the URI changes but the location stays (no search, static file from /files/)
expect "/old/ -> /new/, /chain/ -> /step2/ (two rewrites, the third skipped), /brk/ keeps the location, 301" \
    "$(awk '{ print $4, $5 }' logs/access.log | tr '\n' ' ')" "200 uri=/new/a 200 uri=/step2/a 200 uri=/files/a.txt 301 uri=/redir/a "

step "arguments: appended unless the replacement ends with ?"
: > logs/access.log
req '/args/a?q=1'
req '/noargs/a?q=1'
expect "x=1&q=1, then x=1 only" "$(grep -o 'args=[^ ]*' logs/access.log | tr '\n' ' ')" "args=x=1&q=1 args=x=1 "

step "set and if run on a value stack"
: > logs/error.log
req '/set/z?mode=ok' -H 'X-Name: Bob'
script
expect "the first if is false, the regex if captures Bob" \
    "$(script | grep -cE '^http script if: false$|^http script capture: "Bob"$')" "2"

step "an unset variable is empty and logged"
: > logs/error.log
req '/set/z?mode=ok'
errlog 'uninitialized' | sed -E 's/^(\[[a-z]+\]) \*[0-9]+ /\1 /; s/, client: .*//'
req '/set/z?mode=deny'

step "nocacheable variables are read again, cacheable ones are not"
: > logs/access.log
req /flush/
req /cache/
req /nocache/
cat logs/access.log
# $uri is NGX_HTTP_VAR_NOCACHEABLE: read again after the rewrite. $sent_http_* is cacheable:
# read in the rewrite phase (no response header yet), the "not found" stays for the log
expect "u2 sees the new URI; the log of /cache/ has no content type" \
    "$(curl -s http://127.0.0.1:19140/flush/) $(grep -c 'GET /cache/.* ct=-$' logs/access.log)" \
    "u1=/flush/ u2=/flushed 1"
stop

step "variables are indexed at configuration time"
ctest rw.c "$LAB/" conf/nginx.conf -vars
expect "set adds changeable variables; \$uri is nocacheable, \$sent_http_content_type is not" \
    "$(ctest rw.c "$LAB/" conf/nginx.conf -vars | grep -E '\$(a|uri|sent_http_content_type) ' | awk '{ print $2, $3 }' | tr '\n' ' ')" \
    '$uri nocacheable $sent_http_content_type  $a changeable '

step "set cannot overwrite a built-in variable"
t conf/bad-set.conf
