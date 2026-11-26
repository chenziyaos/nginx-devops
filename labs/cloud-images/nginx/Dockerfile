# nginx 1.31.10 for the cloud-native labs, built from the release tarball.
# Paths, the nginx user, the log symlinks and STOPSIGNAL follow the official nginx image,
# so what a lab shows about this image holds for that one too. The module list is the
# one of tools/build.sh without --with-debug.
#
#   tools/cloud_images.sh      # builds nginx-devops/nginx:1.31.10 and loads it into kind

FROM debian:trixie-slim AS build

ARG NGINX_VERSION=1.31.10
ARG NGINX_SHA256=a9b690957fca84abdae8a9b52d66b1bb459282d7f01fe4b94b498ed8e977bdb3

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl libpcre2-dev libssl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
    && echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c - \
    && tar xzf nginx.tar.gz --strip-components=1

RUN ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/run/nginx.pid \
        --lock-path=/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
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
    && make -j"$(nproc)" \
    && make install DESTDIR=/out \
    && rm -f /out/etc/nginx/*.default

FROM debian:trixie-slim

# curl and procps are not needed by nginx; the labs use them to look inside the pod.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl libpcre2-8-0 libssl3t64 procps zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system nginx \
    && useradd --system --gid nginx --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin nginx \
    && mkdir -p /var/cache/nginx /var/log/nginx \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

COPY --from=build /out/ /
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
