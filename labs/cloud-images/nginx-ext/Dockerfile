# nginx-devops/nginx:1.31.10 plus three ways to extend it, for labs/cloud-07:
#   ngx_http_js_module   njs 1.0.2 with the QuickJS-NG engine (js_engine qjs)
#   ngx_http_curl_module the "curl" example of ngx-rust 0.5.0 (Rust)
#   ngx_http_nocurl_module  the same check in C (nocurl/)
# plus nocurl-451.so, the C module built a second time to answer 451 instead of 403, so the
# lab can replace the .so and see what a reload does with it. The sources of the Rust and
# the C module are copied to /usr/share/nginx-ext/.
# Built like labs/cloud-images/nginx-acme: from the configure arguments of the base image.
#
#   tools/cloud_images.sh      # builds nginx-devops/nginx-ext:1.31.10 after the base image

ARG BASE=nginx-devops/nginx:1.31.10

FROM ${BASE} AS base

FROM debian:trixie-slim AS build

ARG NGINX_VERSION=1.31.10
ARG NGINX_SHA256=a9b690957fca84abdae8a9b52d66b1bb459282d7f01fe4b94b498ed8e977bdb3
# the GitHub archives of the three tags, with their checksums
ARG QUICKJS_NG="quickjs-ng/quickjs v0.18.0 28bcd89aa3683fd2a946537e5ce3f11cc46b5cbf3383c7561aaef3df5ff9f1dd"
ARG NJS="nginx/njs 1.0.2 84a114499fa6878d3ec52b99c1cf2874a91eb0d915408f418a2b1279519f09ae"
ARG NGX_RUST="nginx/ngx-rust v0.5.0 6efad3bcf57ad287e98b50ad9e0621ab1fddaa17add89a5627721e559a758cc8"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cargo cmake curl libclang-dev libpcre2-dev \
        libssl-dev pkg-config rustc zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
    && echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c - \
    && tar xzf nginx.tar.gz --strip-components=1 \
    && for r in "${QUICKJS_NG}" "${NJS}" "${NGX_RUST}"; do \
           set -- $r; \
           d=/src/$(basename "$1"); \
           curl -fsSLo "$d.tar.gz" "https://github.com/$1/archive/refs/tags/$2.tar.gz" \
           && echo "$3  $d.tar.gz" | sha256sum -c - \
           && mkdir "$d" && tar xzf "$d.tar.gz" -C "$d" --strip-components=1 || exit 1; \
       done

# QuickJS-NG as a static library with position-independent code, so it can be linked
# into the njs module; installed with its pkg-config file, which njs looks for.
RUN cmake -S /src/quickjs -B /src/quickjs/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    && cmake --build /src/quickjs/build -j"$(nproc)" \
    && cmake --install /src/quickjs/build

COPY nocurl /src/nocurl
COPY --from=base /usr/sbin/nginx /usr/sbin/nginx

# NJS_LIBXSLT=NO: build njs without the XML module, which needs libxml2 and libxslt
RUN export NJS_LIBXSLT=NO \
    && eval ./configure "$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')" \
        --add-dynamic-module=/src/njs/nginx \
        --add-dynamic-module=/src/ngx-rust/examples \
        --add-dynamic-module=/src/nocurl \
    && make -j"$(nproc)" modules \
    && mkdir -p /out/modules /out/src \
    && cp objs/ngx_http_js_module.so objs/ngx_http_curl_module.so \
        objs/ngx_http_nocurl_module.so /out/modules/ \
    && cp /src/ngx-rust/examples/curl.rs /src/nocurl/ngx_http_nocurl_module.c /out/src/ \
    && sed -i 's/return NGX_HTTP_FORBIDDEN;/return 451;/' /src/nocurl/ngx_http_nocurl_module.c \
    && make -j"$(nproc)" modules \
    && cp objs/ngx_http_nocurl_module.so /out/modules/nocurl-451.so \
    && for f in /out/modules/*.so; do \
           strip -o /tmp/stripped.so "$f" \
           && echo "$(basename "$f") $(stat -c %s "$f") $(stat -c %s /tmp/stripped.so)"; \
       done > /out/src/sizes.txt

FROM ${BASE}
COPY --from=build /out/modules/ /usr/lib/nginx/modules/
# the sources of the Rust and the C module, and sizes.txt (each .so as built and stripped:
# the Rust build keeps its symbols, strip = "none" in ngx-rust's auto/rust)
COPY --from=build /out/src/ /usr/share/nginx-ext/
