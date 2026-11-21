# dev-04: configuration parsing. cf.c (linked against the build's objects by labs/ctest.sh)
# lists the directive table and walks the http{} tree that ngx_init_cycle builds; nginx -t,
# -g and a running nginx show the tokenizer, the dispatcher's errors and a reload.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"
. "$LAB/../ctest.sh"

cf() { ctest cf.c "$@"; }

step "every module's directives in one table"
cf dirs
# ngx_conf_handler scans cycle->modules[] in order and every module's commands[] linearly;
# a name may belong to several modules, the context bits decide which one takes it
expect "server belongs to the http, upstream, stream and stream upstream modules" \
    "$(cf dirs | sed -n 's/^"server" is defined by \([0-9]*\) modules.*/\1/p')" "4"

step "the tokenizer"
start
echo "/hash     $(curl -s http://127.0.0.1:19081/hash)"
echo "/escape   $(curl -s http://127.0.0.1:19081/escape | od -An -c | tr -s ' ') (od -c)"
echo "/variable $(curl -s http://127.0.0.1:19081/variable)"
echo "/brace    $(curl -s http://127.0.0.1:19081/brace)"
expect "\"#\" inside a word is kept; \\n and \\t are expanded; \"{\" after \"\$\" stays in the word; \"{\" ends a word" \
    "$(curl -s http://127.0.0.1:19081/hash)|$(curl -s http://127.0.0.1:19081/escape | od -An -c | tr -s ' ')|$(curl -s http://127.0.0.1:19081/variable)|$(code http://127.0.0.1:19081/brace)" \
    "a#b| 1 \n 2 \t 3|127.0.0.1-x|200"
stop

step "what the parser and the dispatcher reject"
for f in conf/bad/*.conf; do printf '%-10s %s\n' "$(basename "$f" .conf)" "$(t "$f" | grep emerg | head -1)"; done
# the variable is checked in ngx_http_variables_init_vars after the whole http{} is parsed
expect "every error carries file:line except the unknown variable" \
    "$(for f in conf/bad/*.conf; do t "$f" | grep emerg | head -1 | grep -c ' in \$LAB/conf/bad/'; done | tr '\n' ' ')" \
    "1 1 1 1 1 1 1 1 0 "

step "-g is parsed before the configuration file"
echo "-g twice:       $(ngx -t -c conf/tree.conf -g 'worker_processes 2; worker_processes 3;' 2>&1 | grep -m1 emerg | sed 's/^nginx: //')"
echo "-g with block:  $(ngx -t -c conf/tree.conf -g 'events { }' 2>&1 | grep -m1 emerg | sed 's/^nginx: //')"
echo "-g without ;:   $(ngx -t -c conf/tree.conf -g 'worker_processes 2' 2>&1 | grep -m1 emerg | sed 's/^nginx: //')"
echo "-g and file:    $(ngx -t -c conf/nginx.conf -g 'worker_processes 2;' 2>&1 | grep -m1 emerg | sed -e 's/^nginx: //' -e "s#$LAB/#\$LAB/#")"
expect "a directive in -g and in the file: the file's line is the duplicate" \
    "$(ngx -t -c conf/nginx.conf -g 'worker_processes 2;' 2>&1 | grep -c 'duplicate in .*conf/nginx.conf:2')" "1"

step "the http{} tree after ngx_init_cycle"
cf tree "$LAB/" conf/tree.conf
# ngx_http_merge_servers / ngx_http_merge_locations: a server merges with http{}, a location
# with the server{} or the enclosing location; unset values take the parent's
expect "inherited from http{}, from the server, from the enclosing location" \
    "$(cf tree "$LAB/" conf/tree.conf | sed -n 's/^  [a-z]* *location \(.*[^ ]\) *client_max_body_size=\([0-9]*k\).*/\1=\2/p' | tr '\n' ' ')" \
    "/a=5120k /a/b=5120k /c=2048k = /exact=2048k ~ \\.php\$=2048k /=1024k "

step "reload keeps a listening socket whose address is unchanged"
start conf/listen-a.conf
lfds() { lsof -nP -a -p "$(master_pid)" -iTCP -sTCP:LISTEN -Ffn 2>/dev/null | awk '/^f/ { f = substr($0, 2) } /^n/ { print substr($0, 2) " fd " f }' | sort; }
echo "before:"; lfds
before=$(lfds | grep 19082)
reload conf/listen-b.conf
echo "after:"; lfds
expect "19082 keeps its fd, 19083 is closed, 19084 is new" \
    "$( [[ "$(lfds | grep 19082)" == "$before" ]] && echo same) $(lfds | grep -c 19083) $(lfds | grep -c 19084) $(get http://127.0.0.1:19082/)" "same 0 1 b"
stop
