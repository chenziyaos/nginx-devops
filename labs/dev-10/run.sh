# dev-10: the tutorial's module (modules/ngx_http_hello_module), loaded with load_module, and
# fake.c, a do-nothing module built here with a wrong version or signature.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

ln -sfn ../../.nginx/modules modules
U=http://127.0.0.1:19200

# so NAME CFLAGS...: build fake.c into out/run/NAME.so with the flags of the nginx build
so() {
    local name=$1
    shift
    _ctest_prepare
    # shellcheck disable=SC2046
    (cd "$SRC" && cc $(cat "$LAB/out/run/ctest/cflags.txt") -Wno-error $(cat "$LAB/out/run/ctest/incs.txt") \
        "$@" -shared -Wl,-undefined,dynamic_lookup -o "$LAB/out/run/$name.so" "$LAB/fake.c")
}

step "what configure makes of the config file"
cat ../../modules/ngx_http_hello_module/config
echo "--- auto/module, lines 23-31 (the order of a dynamic module)"
sed -n 23,31p "$SRC/auto/module"
echo "--- objs/ngx_http_hello_module_modules.c"
grep -v '^$' "$SRC/objs/ngx_http_hello_module_modules.c"
sig_so=$(strings modules/ngx_http_hello_module.so | grep -E '^[0-9]+,[0-9]+,[0-9]+,[01]+$')
sig_bin=$(strings "$NGINX" | grep -E '^[0-9]+,[0-9]+,[0-9]+,[01]+$' | head -1)
echo "signature in the .so:   $sig_so"
echo "signature in the nginx: $sig_bin"
expect "an HTTP_FILTER module is ordered before copy_filter; the signatures match" \
    "$(grep -A2 'ngx_module_order' "$SRC/objs/ngx_http_hello_module_modules.c" | tail -1 | tr -d ' ,') $([[ $sig_so == "$sig_bin" ]] && echo same)" \
    '"ngx_http_copy_filter_module" same'

start
sleep 0.2

step "the content handler"
get $U/hello
hdrs $U/hello 'content-length' -I
echo "POST: $(code $U/hello -X POST)"
expect "GET 19 bytes, HEAD the same length without a body, POST 405" \
    "$(curl -s $U/hello | wc -c | tr -d ' ') $(curl -sI $U/hello | tr -d '\r' | awk 'tolower($1) == "content-length:" { print $2 }') $(code $U/hello -X POST)" \
    "19 19 405"

step "the location configuration is merged from the server"
for p in /files/a.txt /off/a.txt /var/a.txt; do
    echo "$p: $(hdrs $U$p '^x-hello' | sed 1d | tr '\n' ' ')"
done
expect "inherited, switched off by an empty value, evaluated per request" \
    "$(hdrs $U/files/a.txt '^x-hello' | sed 1d)|$(hdrs $U/off/a.txt '^x-hello' | sed 1d)|$(hdrs $U/var/a.txt '^x-hello' | sed 1d)" \
    "X-Hello: srv||X-Hello: uri=/var/a.txt"

step "the header filter runs before add_header's"
hdrs $U/files/a.txt '^x-'
expect "X-Hello is pushed before X-Add" "$(hdrs $U/files/a.txt '^x-' | sed 1d | cut -d: -f1 | tr '\n' ' ')" "X-Hello X-Add "

step "the variable is read again by the access log"
: > logs/access.log
get $U/count > /dev/null
get $U/count > /dev/null
accesslog
expect "set reads the count before the handler, the log after it" "$(accesslog | cut -d' ' -f3- | tr '\n' ' ')" \
    "before=4 now=5 before=5 now=6 "

step "what ngx_add_module refuses"
so oldver -DFAKE_VERSION=1030007
so badsig -DFAKE_SIGNATURE='"8,4,8,0"'
for c in oldver badsig late twice; do t conf/$c.conf | grep -E 'emerg' || true; done
expect "wrong version, wrong signature, too late, twice" \
    "$(for c in oldver badsig late twice; do t conf/$c.conf | grep -c emerg; done | tr '\n' ' ')" "1 1 1 1 "

step "each worker has its own counter, a reload starts from zero"
echo "before reload: $(curl -s $U/total)"
reload
curl -s -o /dev/null $U/hello
echo "after reload and one request: $(curl -s $U/total)"
expect "the new worker counts from 1" "$(curl -s $U/total)" "1"
