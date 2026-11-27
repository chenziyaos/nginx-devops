# nginx-devops/nginx:1.31.10 plus the nginx-acme module (Rust), loaded with load_module.
# A dynamic module has to be built from the same nginx sources with the same configure
# arguments as the binary that loads it, or nginx refuses it as "not binary compatible".
# The build stage takes the arguments from `nginx -V` of the base image.
#
#   tools/cloud_images.sh      # builds nginx-devops/nginx-acme:1.31.10 after the base image

ARG BASE=nginx-devops/nginx:1.31.10

FROM ${BASE} AS base

FROM debian:trixie-slim AS build

ARG NGINX_VERSION=1.31.10
ARG NGINX_SHA256=a9b690957fca84abdae8a9b52d66b1bb459282d7f01fe4b94b498ed8e977bdb3
ARG ACME_VERSION=0.4.2
ARG ACME_SHA256=60973cf002764fa0c01730068a8d14c2d469781a60902d8e74a8fb59593ffb35

# cargo and rustc of trixie are 1.85, nginx-acme needs 1.81 or later;
# libclang is for bindgen, which generates the Rust bindings of the nginx headers.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cargo curl libclang-dev libpcre2-dev libssl-dev \
        pkg-config rustc zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
    && echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c - \
    && tar xzf nginx.tar.gz --strip-components=1 \
    && curl -fsSLo acme.tar.gz \
        "https://github.com/nginx/nginx-acme/releases/download/v${ACME_VERSION}/nginx-acme-${ACME_VERSION}.tar.gz" \
    && echo "${ACME_SHA256}  acme.tar.gz" | sha256sum -c - \
    && mkdir nginx-acme && tar xzf acme.tar.gz -C nginx-acme --strip-components=1

COPY --from=base /usr/sbin/nginx /usr/sbin/nginx
RUN eval ./configure "$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')" \
        --add-dynamic-module=/src/nginx-acme \
    && make -j"$(nproc)" modules

FROM ${BASE}
COPY --from=build /src/objs/ngx_http_acme_module.so /usr/lib/nginx/modules/
