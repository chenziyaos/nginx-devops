#!/usr/bin/env bash
# Build the nginx used by every lab in this repo into ./.nginx (no root needed).
#
#   tools/build.sh            # fetch release-1.31.9, configure, make, install
#   NGINX_REF=release-1.30.7 tools/build.sh   # build another tag (labs are verified on 1.31.9 only)
#
# Source goes to ./.nginx-src/<ref>, the install prefix is ./.nginx.
# Every module under modules/ (the tutorial's own code) is built as a dynamic module.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REF=${NGINX_REF:-release-1.31.9}
SRC="$ROOT/.nginx-src/$REF"
PREFIX="$ROOT/.nginx"

if [[ ! -d "$SRC" ]]; then
    git clone --quiet --depth 1 --branch "$REF" https://github.com/nginx/nginx.git "$SRC"
fi

cc_opt="-O0 -g"
ld_opt=""
if [[ "$(uname -s)" == Darwin ]] && command -v brew >/dev/null; then
    # Homebrew keeps OpenSSL and PCRE2 outside the default search path.
    for pkg in openssl@3 pcre2; do
        p=$(brew --prefix "$pkg")
        cc_opt+=" -I$p/include"
        ld_opt+=" -L$p/lib"
    done
fi

extra=()
for m in "$ROOT"/modules/*/; do
    if [[ -f "$m/config" ]]; then
        extra+=(--add-dynamic-module="${m%/}")
    fi
done

cd "$SRC"
./auto/configure \
    --prefix="$PREFIX" \
    --with-debug \
    --with-compat \
    --with-threads \
    --with-control-api \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_stub_status_module \
    --with-http_json_module \
    --with-http_realip_module \
    --with-http_auth_request_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    ${extra[@]+"${extra[@]}"} \
    --with-cc-opt="$cc_opt" \
    --with-ld-opt="$ld_opt" >/dev/null

make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
make install >/dev/null

"$PREFIX/sbin/nginx" -V
