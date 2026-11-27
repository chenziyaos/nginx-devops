# nginx-devops/nginx:1.31.10 plus nginx-otel (ngx_otel_module, C++), loaded with load_module.
# Built like labs/cloud-images/nginx-acme: from the configure arguments of the base image.
# The module's CMake build downloads and compiles gRPC 1.49.4 and opentelemetry-cpp 1.11.0,
# the versions pinned in its CMakeLists.txt, so the first build takes a while.
#
#   tools/cloud_images.sh      # builds nginx-devops/nginx-otel:1.31.10 after the base image

ARG BASE=nginx-devops/nginx:1.31.10

FROM ${BASE} AS base

FROM debian:trixie-slim AS build

ARG NGINX_VERSION=1.31.10
ARG NGINX_SHA256=a9b690957fca84abdae8a9b52d66b1bb459282d7f01fe4b94b498ed8e977bdb3
ARG OTEL_VERSION=v0.1.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl git libc-ares-dev libpcre2-dev libre2-dev \
        libssl-dev pkg-config zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
    && echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c - \
    && tar xzf nginx.tar.gz --strip-components=1 \
    && git -c advice.detachedHead=false clone -q --depth 1 --branch "${OTEL_VERSION}" \
        https://github.com/nginxinc/nginx-otel /src/nginx-otel

COPY --from=base /usr/sbin/nginx /usr/sbin/nginx
RUN eval ./configure "$(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')" \
        --add-dynamic-module=/src/nginx-otel \
    && make -j"$(nproc)" modules

FROM ${BASE}
# gRPC is built with the system c-ares (gRPC_CARES_PROVIDER package in nginx-otel's
# CMakeLists.txt), so the module needs its shared library at run time
RUN apt-get update \
    && apt-get install -y --no-install-recommends libc-ares2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/objs/ngx_otel_module.so /usr/lib/nginx/modules/
