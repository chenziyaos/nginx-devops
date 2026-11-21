#!/usr/bin/env bash
# Rebuild only the dynamic modules under modules/ against the nginx already in ./.nginx,
# without touching the nginx binary. Use it while editing a module:
#   tools/build_modules.sh        # writes .nginx/modules/<name>.so
# It configures a scratch copy of the source with the same arguments as `nginx -V`
# (required by --with-compat), so the result loads into that binary.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NGINX="$ROOT/.nginx/sbin/nginx"
[[ -x "$NGINX" ]] || { echo "run tools/build.sh first" >&2; exit 2; }

ref="release-$("$NGINX" -v 2>&1 | sed 's#.*nginx/##')"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$ROOT/.nginx-src/$ref/." "$work/"
rm -rf "$work/objs"

# The configure line printed by `nginx -V` already lists every --add-dynamic-module;
# drop those and add the current modules/ directories instead.
args=$("$NGINX" -V 2>&1 | sed -n 's/^configure arguments: //p' | sed -E 's/--add-dynamic-module=[^ ]+//g')
mods=()
for m in "$ROOT"/modules/*/; do
    if [[ -f "$m/config" ]]; then
        mods+=(--add-dynamic-module="${m%/}")
    fi
done

cd "$work"
eval ./auto/configure "$args" '"${mods[@]}"' >/dev/null
make -f objs/Makefile modules >/dev/null
mkdir -p "$ROOT/.nginx/modules"
cp objs/*.so "$ROOT/.nginx/modules/"
ls "$ROOT/.nginx/modules/"
