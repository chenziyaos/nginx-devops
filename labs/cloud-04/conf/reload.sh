#!/bin/sh
# Reload nginx through its control API whenever the ConfigMap volume changes.
# kubelet updates a ConfigMap volume by pointing ..data at a new directory, so a new
# target of that link means a complete new set of files.
trap 'exit 0' TERM
dir=/etc/nginx/live
sock=/run/ctl/nginx.sock
last=$(readlink "$dir/..data")
while sleep 1; do
    now=$(readlink "$dir/..data")
    [ "$now" = "$last" ] && continue
    last=$now
    code=$(curl -s --unix-socket "$sock" -X PATCH -o /tmp/patch.json -w '%{http_code}' \
        http://localhost/1/control/config)
    printf 'reload: %s %s\n' "$code" "$(cat /tmp/patch.json)"
done
