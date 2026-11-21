# ops-13: reproduce each common status code once and keep the error.log line that explains
# it; nginx -T and a debug log. Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:18260
# last: the last access.log line
last() { tail -1 logs/access.log; }
# why REGEX: the matching error.log lines, with the connection number and client address
# taken out
why() { errlog "$1" | sed -E 's/\*[0-9]+ //; s/, client: 127.0.0.1//; s/, server: [^,]*//; s/, host: "[^"]*"//; s#'"$LAB"'/#$LAB/#g'; }
# in_default REGEX: how many lines the default-level error log has for it
in_default() { grep -cE "$1" logs/error-default.log || true; }
# raw BYTES: send raw bytes, print the status line of the reply (or "closed without a reply")
raw() {
    python3 - "$1" <<'PY'
import socket, sys, time
s = socket.create_connection(('127.0.0.1', 18260))
s.sendall(sys.argv[1].encode().decode('unicode_escape').encode('latin-1'))
data = b''
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
print(data.split(b'\r\n', 1)[0].decode() if data else 'closed without a reply')
PY
}

start

step "nginx -T prints every file it read"
ngx -T -c conf/nginx.conf 2>&1 | grep -E '^# configuration file|syntax is ok' | sed -e "s#$LAB/#\$LAB/#g" -E -e 's/^nginx: //'
expect "the main file and the included one are both dumped" \
    "$(ngx -T -c conf/nginx.conf 2> /dev/null | grep -c '^# configuration file')" "2"

step "400: a request nginx cannot accept"
echo "HTTP/1.1 without Host: $(code $U/ -H 'Host:')"
last
why 'without "Host"'
echo "a space in a header name: $(code $U/ -H 'Bad Header: x')"
echo "an underscore in a header name: $(code $U/hdr -H 'X_Token: 1') $(get $U/hdr -H 'X_Token: 1')"
why 'invalid header line'
expect "the space is fatal, the underscore header is dropped; the default error log has none of the three" \
    "$(code $U/ -H 'Bad Header: x') $(get $U/hdr -H 'X_Token: 1') $(in_default 'without "Host"|invalid header line')" "400 x_token=[] 0"

step "414 and 400 for header buffers that are too small"
long=$(printf 'a%.0s' $(seq 1100))
echo "1100-byte URI: $(code "$U/$long")"
why 'too long URI' | sed -E 's#(/a{8})a*#\1...#'
echo "1100-byte header line: $(code $U/ -H "X-Long: $long")"
last
why 'too long header line' | sed -E 's/(X-Long: a{8})a*\.\.\./\1.../'
expect "a long URI gets 414; a long header line gets 494, sent and logged as 400" \
    "$(code "$U/$long") $(code $U/ -H "X-Long: $long") $(last | awk '{ print $1 }')" "414 400 400"

step "413: the body is larger than client_max_body_size"
echo "2000-byte body: $(code $U/ --data-binary @<(head -c 2000 /dev/zero))"
last
why 'too large body'
expect "Content-Length is checked before the body is read; the line is at error level" \
    "$(in_default 'too large body')" "1"

step "408: the request header did not arrive within client_header_timeout"
raw 'GET / HTTP/1.1\r\nHost: a\r\n'
last
why 'client timed out'
expect "nginx closes without a reply and logs 408" "$(last | awk '{ print $1 }')" "408"

step "403, 404 and 500 from the configuration and the file system"
for p in /dir/ /nothing /loop; do printf '%-9s %s\n' "$p" "$(code $U$p)"; done
why 'forbidden|open\(\)|cycle'
expect "a directory without an index, a missing file, a rewrite loop" \
    "$(for p in /dir/ /nothing /loop; do code $U$p; done | tr '\n' ' ')" "403 404 500 "

step "502: five different upstream failures"
curl -s -o /dev/null $U/refused
curl -s -o /dev/null $U/closed
curl -s -o /dev/null $U/reset
curl -s -o /dev/null $U/big
curl -s -o /dev/null $U/nolive
curl -s -o /dev/null $U/nolive
grep -E ' /(refused|closed|reset|big|nolive) ' logs/access.log
why 'connect\(\) failed|prematurely closed|closed connection \(|too big header|no live' | sed -E 's/, (request|upstream): .*//'
expect "six requests, six 502" "$(grep -cE '^502 .* /(refused|closed|reset|big|nolive) ' logs/access.log)" "6"

step "504: the upstream did not answer within proxy_read_timeout"
curl -s -o /dev/null http://127.0.0.1:18261/slow    # uses the one request limit_req lets through
echo "front: $(code $U/t504)"
last
why 'upstream timed out' | sed -E 's/, (request|upstream): .*//'
expect "the backend holds the request, the proxy gives up after 1 s" "$(last)" "504 GET /t504 up=504"

step "499: the client gave up first"
curl -s -o /dev/null http://127.0.0.1:18261/slow2
curl -s -o /dev/null --max-time 0.5 $U/t499 || true
sleep 0.2
last
why 'reported that client prematurely closed' | sed -E 's/ while .*//'
expect "the status is 499 and the upstream status is empty" "$(last)" "499 GET /t499 up=-"

step "503: limit_req rejected the request"
echo "two requests: $(seq_codes 2 $U/limited)"
last
why 'limiting requests' | sed -E 's/excess: [0-9.]+/excess: <n>/; s/, request: .*//'
expect "the second request within a minute is rejected" "$(last | awk '{ print $1 }')" "503"

step "reading one request in the debug log"
curl -s -o /dev/null http://127.0.0.1:18262/a?b=1
sleep 0.1
# the lines that mark the main steps; each debug line starts with time, pid#tid and *conn
grep -aE 'http request line:|http uri:|http args:|generic phase: [0-9]+|rewrite phase: [0-9]+|test location:|using configuration|http finalize request:|http close request' logs/debug.log \
    | sed -E 's/^[0-9\/]+ [0-9:]+ \[debug\] [0-9]+#[0-9]+: \*[0-9]+ /[debug] /; ' | awk '!seen[$0]++'
expect "the request line, the phases and the finalize call are all there" \
    "$(grep -acE 'http request line: "GET /a\?b=1 HTTP/1.1"|using configuration "/"|http finalize request: 0' logs/debug.log)" "3"

stop
