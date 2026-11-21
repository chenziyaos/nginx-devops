# ops-05: static files, conditional requests, Range, gzip, expires, open_file_cache, keepalive
# and request body limits. Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"

U=http://127.0.0.1:18100

# fixed mtimes, so Last-Modified and ETag do not depend on the checkout time
TZ=UTC touch -t 202601020304.05 html/cond/a.txt html/range/r.txt html/gzip/*
TZ=UTC touch -t 202001010000.00 html/exp/e.txt
mtime() { date -r "$1" +%s; }
size() { wc -c < "$1" | tr -d ' '; }

# files that the lab changes live under out/run/
mkdir -p out/run/sf out/run/gzs out/run/ofc
head -c 200000 /dev/zero > out/run/sf/big.bin
cp html/gzip/index.html out/run/gzs/app.js
gzip -9 -n -c out/run/gzs/app.js > out/run/gzs/app.js.gz
echo v1 > out/run/ofc/f.txt

start

step "sendfile is off by default"
curl -s -o /dev/null $U/sf-default/big.bin
curl -s -o /dev/null $U/sf-on/big.bin
for f in sf-default sf-on; do
    echo "$f: sendfile lines $(grep -ac 'sendfile: @' logs/$f.log || true), writev lines $(grep -ac 'writev: ' logs/$f.log || true)"
done
grep -a 'sendfile: @0 ' logs/sf-on.log | head -1 | sed -E 's/^.*\*[0-9]+ //'
echo "writev sizes without sendfile: $(grep -a 'writev: ' logs/sf-default.log | sed -E 's/^.*writev: ([0-9]+) of.*/\1/' | tr '\n' ' ')"
expect "without sendfile on the file is read and written with writev; with it, sendfile() sends it" \
    "$(grep -ac 'sendfile: @' logs/sf-default.log || true) $([[ $(grep -ac 'sendfile: @' logs/sf-on.log) -gt 0 ]] && echo some)" "0 some"

step "Last-Modified and ETag"
hdrs $U/cond/a.txt 'last-modified|etag|content-length'
etag=$(printf '"%x-%x"' "$(mtime html/cond/a.txt)" "$(size html/cond/a.txt)")
lm=$(curl -s -o /dev/null -D - $U/cond/a.txt | tr -d '\r' | sed -n 's/^Last-Modified: //p')
echo "ETag computed from the file: $etag"
expect "the ETag is the mtime and the size in hex" \
    "$(curl -s -o /dev/null -D - $U/cond/a.txt | tr -d '\r' | sed -n 's/^ETag: //p')" "$etag"

step "conditional requests"
later=$(TZ=GMT date -r $(( $(mtime html/cond/a.txt) + 3600 )) '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null \
    || TZ=GMT date -d "@$(( $(mtime html/cond/a.txt) + 3600 ))" '+%a, %d %b %Y %H:%M:%S GMT')
earlier=$(TZ=GMT date -r $(( $(mtime html/cond/a.txt) - 3600 )) '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null \
    || TZ=GMT date -d "@$(( $(mtime html/cond/a.txt) - 3600 ))" '+%a, %d %b %Y %H:%M:%S GMT')
r1=$(code $U/cond/a.txt -H "If-None-Match: $etag")
r2=$(code $U/cond/a.txt -H "If-Modified-Since: $lm")
r3=$(code $U/cond/a.txt -H "If-Modified-Since: $later")
r4=$(code $U/ims-before/a.txt -H "If-Modified-Since: $later")
r5=$(code $U/cond/a.txt -H "If-None-Match: $etag" -H "If-Modified-Since: $earlier")
r6=$(code $U/cond/a.txt -H "If-None-Match: W/$etag")
echo "If-None-Match = ETag:                         $r1"
echo "If-Modified-Since = Last-Modified:            $r2"
echo "If-Modified-Since one hour later (exact):     $r3"
echo "If-Modified-Since one hour later (before):    $r4"
echo "matching ETag + If-Modified-Since one hour earlier: $r5"
echo "If-None-Match = W/ETag:                       $r6"
expect "both validators must agree; exact needs the same second; INM compares weakly" \
    "$r1 $r2 $r3 $r4 $r5 $r6" "304 304 200 304 200 304"

step "what a 304 keeps"
hdrs $U/cond/a.txt 'etag|last-modified|content-length|accept-ranges' -H "If-None-Match: $etag"
expect "a 304 has no Content-Length and no Accept-Ranges" \
    "$(hdrs $U/cond/a.txt 'content-length|accept-ranges' -H "If-None-Match: $etag" | wc -l | tr -d ' ')" "1"

step "Range"
size_r=$(size html/range/r.txt)
for r in 'bytes=0-4' 'bytes=-3' 'bytes=24-100'; do
    printf '%-14s %s\n' "$r" "$(curl -s -D out/run/h.txt -o out/run/b.txt -w '%{http_code}' -H "Range: $r" $U/range/r.txt) $(tr -d '\r' < out/run/h.txt | sed -n 's/^Content-Range: //p') [$(cat out/run/b.txt)]"
done
printf '%-14s %s\n' "bytes=0-1,4-5" "$(curl -s -D out/run/h.txt -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1,4-5' $U/range/r.txt) $(tr -d '\r' < out/run/h.txt | sed -n 's/^Content-Type: //p' | sed 's/boundary=.*/boundary=.../')"
printf '%-14s %s\n' "max_ranges 1" "$(code $U/range1/r.txt -H 'Range: bytes=0-1,4-5') (two ranges)"
printf '%-14s %s\n' "bytes=30-40" "$(curl -s -D out/run/h.txt -o /dev/null -w '%{http_code}' -H 'Range: bytes=30-40' $U/range/r.txt) $(tr -d '\r' < out/run/h.txt | sed -n 's/^Content-Range: //p')"
printf '%-14s %s\n' "stale If-Range" "$(code $U/range/r.txt -H 'Range: bytes=0-4' -H 'If-Range: "0-0"')"
expect "206 per range, 200 above max_ranges or with a stale If-Range, 416 past the end" \
    "$(code $U/range/r.txt -H 'Range: bytes=0-4') $(code $U/range1/r.txt -H 'Range: bytes=0-1,4-5') $(code $U/range/r.txt -H 'Range: bytes=0-4' -H 'If-Range: "0-0"') $(curl -s -o /dev/null -D - -H 'Range: bytes=30-40' $U/range/r.txt | tr -d '\r' | awk 'NR == 1 { s = $2 } /^Content-Range:/ { print s, $2, $3 }')" \
    "206 200 200 416 bytes */$size_r"

step "gzip with the default settings"
gz() { curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip' "$@" | tr -d '\r' | grep -ci '^content-encoding: gzip' || true; }
printf '%-34s %s\n' "index.html (text/html, 307 bytes)" "$(gz $U/gzip/index.html)"
printf '%-34s %s\n' "style.css (text/css)" "$(gz $U/gzip/style.css)"
printf '%-34s %s\n' "tiny.html ($(size html/gzip/tiny.html) bytes)" "$(gz $U/gzip/tiny.html)"
printf '%-34s %s\n' "index.html with Via: 1.1 cdn" "$(gz $U/gzip/index.html -H 'Via: 1.1 cdn')"
printf '%-34s %s\n' "index.html over HTTP/1.0" "$(gz $U/gzip/index.html --http1.0)"
expect "only text/html of at least 20 bytes, over HTTP/1.1, without a Via header (1 = gzipped)" \
    "$(gz $U/gzip/index.html)$(gz $U/gzip/style.css)$(gz $U/gzip/tiny.html)$(gz $U/gzip/index.html -H 'Via: 1.1 cdn')$(gz $U/gzip/index.html --http1.0)" "10000"

step "what gzip changes in the response"
hdrs $U/gzip/index.html 'content-length|content-encoding|accept-ranges|etag|vary|transfer-encoding' -H 'Accept-Encoding: gzip'
echo "with Range: bytes=0-9 -> $(code $U/gzip/index.html -H 'Accept-Encoding: gzip' -H 'Range: bytes=0-9')"
expect "the gzipped response is chunked, has a weak ETag and ignores Range" \
    "$(hdrs $U/gzip/index.html 'content-length|accept-ranges' -H 'Accept-Encoding: gzip' | wc -l | tr -d ' ') $(hdrs $U/gzip/index.html etag -H 'Accept-Encoding: gzip' | sed -n 's/^ETag: \(W\/\).*/\1/p') $(code $U/gzip/index.html -H 'Accept-Encoding: gzip' -H 'Range: bytes=0-9')" \
    "1 W/ 200"

step "gzip_static"
hdrs $U/gzs/app.js 'content-length|content-encoding' -H 'Accept-Encoding: gzip'
hdrs $U/gzs/app.js 'content-length|content-encoding'
echo "app.js $(size out/run/gzs/app.js) bytes, app.js.gz $(size out/run/gzs/app.js.gz) bytes"
expect "a client that accepts gzip gets app.js.gz as is, others get app.js" \
    "$(hdrs $U/gzs/app.js 'content-length' -H 'Accept-Encoding: gzip' | sed -n 's/^Content-Length: //p') $(hdrs $U/gzs/app.js 'content-length' | sed -n 's/^Content-Length: //p')" \
    "$(size out/run/gzs/app.js.gz) $(size out/run/gzs/app.js)"

step "expires"
hdrs $U/exp/e.txt 'cache-control|last-modified'
hdrs $U/exp-mod/e.txt 'cache-control|last-modified'
hdrs $U/exp/missing.txt 'cache-control'
expect "1h from now is max-age=3600; 1h after a 2020 mtime is in the past; a 404 gets nothing" \
    "$(hdrs $U/exp/e.txt cache-control | sed -n 's/^Cache-Control: //p') $(hdrs $U/exp-mod/e.txt cache-control | sed -n 's/^Cache-Control: //p') $(hdrs $U/exp/missing.txt cache-control | wc -l | tr -d ' ')" \
    "max-age=3600 no-cache 1"

step "open_file_cache keeps the old file"
echo "before: ofc=$(get $U/ofc/f.txt) noofc=$(get $U/noofc/f.txt)"
echo v2 > out/run/ofc/f.txt.new
mv out/run/ofc/f.txt.new out/run/ofc/f.txt
echo "after mv: ofc=$(get $U/ofc/f.txt) noofc=$(get $U/noofc/f.txt)"
expect "within open_file_cache_valid the cached descriptor still points to the old file" \
    "$(get $U/ofc/f.txt) $(get $U/noofc/f.txt)" "v1 v2"

step "keepalive_requests and the Keep-Alive header"
K=http://127.0.0.1:18102/cond/a.txt
: > logs/access.log
conns=$(curl -s -w '%{num_connects} ' -o /dev/null -o /dev/null -o /dev/null -o /dev/null $K $K $K $K)
echo "num_connects per request: $conns"
sleep 0.2
echo "access.log \$connection_requests: $(awk '{ print $4 }' logs/access.log | tr '\n' ' ')"
curl -s -D - -o /dev/null -o /dev/null -o /dev/null $K $K $K | tr -d '\r' | grep -iE '^(connection|keep-alive):'
expect "the third request on a connection gets Connection: close, the fourth opens a new one" \
    "$conns" "1 0 0 1 "

step "client_max_body_size"
head -c 2000 /dev/zero > out/run/2000.bin
head -c 500 /dev/zero > out/run/500.bin
: > logs/error.log
echo "500 bytes:           $(code $U/upload/ --data-binary @out/run/500.bin) $(curl -s --data-binary @out/run/500.bin $U/upload/)"
echo "2000 bytes:          $(code $U/upload/ --data-binary @out/run/2000.bin)"
echo "2000 bytes, chunked: $(code $U/upload/ --data-binary @out/run/2000.bin -H 'Transfer-Encoding: chunked')"
errlog 'too large' | sed -E 's/\*[0-9]+ //; s/, client: .*//'
expect "Content-Length is checked when the location is chosen, a chunked body while it is read" \
    "$(errlog 'too large body: 2000 bytes' | wc -l | tr -d ' ') $(errlog 'too large chunked body' | wc -l | tr -d ' ')" "1 1"

step "client_body_buffer_size"
head -c 100000 /dev/zero > out/run/100k.bin
echo "page size $(getconf PAGESIZE), default client_body_buffer_size = 2 pages = $(( 2 * $(getconf PAGESIZE) ))"
echo "100000 bytes to a location with client_body_buffer_size 8k: $(curl -s --data-binary @out/run/100k.bin $U/upload-big/)"
errlog 'buffered to a temporary file' | sed -E "s/\*[0-9]+ //; s#$LAB/#\$LAB/#; s/[0-9]{10}/NNNNNNNNNN/; s/, client: .*//"
expect "a body larger than the buffer is written to client_body_temp" \
    "$(errlog 'a client request body is buffered to a temporary file' | wc -l | tr -d ' ')" "1"

stop
