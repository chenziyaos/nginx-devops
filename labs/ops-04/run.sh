# ops-04: which server and which location handle a request. One config, one server per topic.
# Expected values come from the source (see HYPOTHESES.md), not from a previous run.
. "$(dirname "$0")/../lib.sh"

# row PORT HOST URI [-H 'X: y']: "host uri [header] -> response body"
row() {
    local port=$1 host=$2 uri=$3
    shift 3
    printf '%-18s %-18s %-13s -> %s\n' "$host" "$uri" "${2:-}" \
        "$(curl -s --path-as-is -H "Host: $host" "$@" "http://127.0.0.1:$port$uri" | head -1)"
}

# answers COLUMN: the response bodies of the rows printed so far in this step, one per line
answers() { sed -E 's/^.* -> //' out/run/rows.txt; }

start conf/nginx.conf

step "server_name: exact, wildcards, regex, default"
{
    row 18080 first.test /
    row 18080 example.com /
    row 18080 EXAMPLE.com. /
    row 18080 a.example.com /
    row 18080 x.y.example.com /
    row 18080 a.api.example.com /
    row 18080 www.foo.org /
    row 18080 www.foo.net /
    row 18080 42.num.test /
    row 18080 dot.test /
    row 18080 a.dot.test /
    row 18080 unknown.test /
    row 18081 a.test /
    row 18081 unknown.test /
} | tee out/run/rows.txt
expect "exact beats wildcards, *.x beats x.*, wildcards beat regex, then the default" \
    "$(answers | tr '\n' '|')" \
    "first.test|example.com|example.com|*.example.com|*.example.com|*.api.example.com|www.*|www.*|regex num, n=42|.dot.test|.dot.test|first.test|a.test|b.test (default_server)|"

step "requests without a usable Host"
nohost=$(curl -s -0 -H 'Host:' http://127.0.0.1:18080/); echo "HTTP/1.0 without Host -> $nohost"
bad1=$(code http://127.0.0.1:18080/ -H 'Host: a b'); echo "Host: a b -> $bad1"
bad2=$(code http://127.0.0.1:18080/ -H 'Host: a..b'); echo "Host: a..b -> $bad2"
errlog 'client sent invalid host' | sed -E 's/^\[info\] \*[0-9]+ //; s/, client:.*//'
expect "no Host goes to the default server" "$nohost" "first.test"
expect "spaces and empty labels in Host are rejected with 400" "$bad1 $bad2" "400 400"

step "location: prefix, exact, ^~ and regex"
{
    row 18082 l.test /
    row 18082 l.test /index.html
    row 18082 l.test /docs/a.txt
    row 18082 l.test /docs/a.png
    row 18082 l.test /static/a.png
    row 18082 l.test /static/img/a.png
    row 18082 l.test /exact
    row 18082 l.test /exact/more
    row 18082 l.test /api
    row 18082 l.test /api/v2/users
    row 18082 l.test /report.PDF
} | tee out/run/rows.txt
expect "= stops, ^~ on the longest prefix skips regex, otherwise the first matching regex wins" \
    "$(answers | tr '\n' '|')" \
    '= /|/|/docs/|~ \.(png|jpg)|^~ /static/|~ \.(png|jpg)|= /exact|/exact|~ ^/api|~ ^/api/v[0-9]+/|~* \.pdf|'

step "location: case on macOS"
uname -s
row 18082 l.test /DOCS/a.txt | tee out/run/rows.txt
# NGX_HAVE_CASELESS_FILESYSTEM is defined for darwin: prefixes compare caseless, "~" acts as "~*"
if [[ $(uname -s) == Darwin ]]; then want=/docs/; else want=/; fi
expect "prefix match ignores case only where nginx treats the file system as caseless" "$(answers)" "$want"

step "predicate locations"
{
    row 18083 p.test /
    row 18083 p.test / -H 'X-Beta: 1'
    row 18083 p.test / -H 'X-Beta: 0'
    row 18083 p.test / -H 'X-Beta: 00'
    row 18083 p.test / -H 'X-Beta: no'
    row 18083 p.test /a.json -H 'X-Beta: 1'
    row 18083 p.test /stable/x -H 'X-Beta: 1'
    row 18083 p.test /admin/x
    row 18083 p.test /admin/x -H 'X-Admin: yes'
    row 18083 p.test /admin/x -H 'X-Beta: 1'
} | tee out/run/rows.txt
expect "true = not empty and not \"0\"; regex first; ^~ skips predicates; a predicate beats a plain prefix" \
    "$(answers | tr '\n' '|')" \
    '/|1 (predicate)|/|00 (predicate)|no (predicate)|~ \.json|^~ /stable/|/admin/|/admin/ > yes (nested predicate)|1 (predicate)|'
n130=$(grep -c 'predicate_locations' ../../.nginx-src/release-1.30.8/src/http/ngx_http_core_module.c || true)
n131=$(grep -c 'predicate_locations' ../../.nginx-src/release-1.31.10/src/http/ngx_http_core_module.c || true)
echo "lines with predicate_locations in ngx_http_core_module.c: 1.30.8 $n130, 1.31.10 $n131"
expect "1.30.8 has no predicate locations" "$n130" "0"

step "try_files"
: > logs/error.log
{
    row 18084 t.test /app.js
    row 18084 t.test /no/such/page
    row 18084 t.test /api/x
} | tee out/run/rows.txt
hdrs http://127.0.0.1:18084/docs '^location:' | tee out/run/docs.txt
strict=$(code http://127.0.0.1:18084/strict/none); echo "/strict/none status: $strict"
expect "files are tried in order, the last argument is where to go" \
    "$(answers | tr '\n' '|')" "app|index|named location, uri=/api/x|"
# try_files strips the slash of "$uri/" after the directory test, so the URI stays /docs
# and the static module answers a directory without a slash with 301
expect "\$uri/ only tests the directory; static then redirects /docs to /docs/" \
    "$(tr '\n' '|' < out/run/docs.txt)" "HTTP/1.1 301 Moved Permanently|Location: http://127.0.0.1:18084/docs/|"
expect "=404 is returned as is" "$strict" "404"

step "try_files: what is tested for /no/such/page"
: > logs/error.log
curl -s -o /dev/null http://127.0.0.1:18084/no/such/page
errlog 'trying to use' | sed -E 's/^\[debug\] \*[0-9]+ //; s/: ("[^"]*") .*/: \1/' | tee out/run/tried.txt
expect "two checks for the URI, then the fallback, then the fallback's own check after the redirect" \
    "$(tr '\n' '|' < out/run/tried.txt)" \
    'trying to use file: "/no/such/page"|trying to use dir: "/no/such/page"|trying to use file: "/index.html"|trying to use file: "/index.html"|'

step "try_files: a fallback that matches the same location loops"
loop=$(code http://127.0.0.1:18084/loop/x); echo "/loop/x -> $loop"
errlog 'redirection cycle' | sed -E 's/^\[error\] \*[0-9]+ //; s/, client:.*//'
expect "10 internal redirects end with 500" "$loop $(errlog 'redirection cycle' | wc -l | tr -d ' ')" "500 1"

step "root and alias"
{
    row 18085 r.test /root-demo/x.txt
    row 18085 r.test /files/a.txt
    row 18085 r.test /img/a.txt
    row 18085 r.test /img../secret.txt
    row 18085 r.test /cap/a.txt
} | tee out/run/rows.txt
dotdot=$(code http://127.0.0.1:18085/files/../secret.txt --path-as-is); echo "/files/../secret.txt status: $dotdot"
expect "root appends the URI, alias replaces the location prefix" \
    "$(answers | tr '\n' '|')" "root x|alias a|alias a|secret|alias a|"
expect "a real ../ segment is normalized away before matching" "$dotdot" "404"

step "return and rewrite run before access control"
{
    row 18086 ph.test /deny-return/
    row 18086 ph.test /rewrite-last/abc
} | tee out/run/rows.txt
deny=$(code http://127.0.0.1:18086/deny-static/x); echo "/deny-static/x status: $deny"
brk=$(code http://127.0.0.1:18086/rewrite-break/abc); echo "/rewrite-break/abc status: $brk"
errlog 'target/abc.*failed' | sed -E 's#^\[error\] \*[0-9]+ open\(\) "[^"]*/labs/ops-04/#open() "$LAB/#; s/, client:.*//'
expect "return answers before deny is checked; last re-runs location matching" \
    "$(answers | tr '\n' '|')" "return ran, deny did not|location /target/, uri=/target/abc|"
expect "deny works for static content; break keeps the request in its location" "$deny $brk" "403 404"

stop
