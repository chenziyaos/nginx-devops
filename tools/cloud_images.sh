#!/usr/bin/env bash
# Build the images of the cloud-native labs (labs/cloud-*) and load them into the kind cluster.
#
#   tools/cloud_images.sh                     # cluster "lab"
#   KIND_CLUSTER=other tools/cloud_images.sh
#
# Needs docker and kind. Proxy variables set in the environment (http_proxy, https_proxy,
# no_proxy and their upper-case forms) are passed to docker build as build arguments.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLUSTER=${KIND_CLUSTER:-lab}

kind get clusters 2>/dev/null | grep -qx "$CLUSTER" \
    || { echo "no kind cluster named $CLUSTER" >&2; exit 2; }

args=()
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [[ -n "${!v:-}" ]]; then
        args+=(--build-arg "$v=${!v}")
    fi
done

# image TAG DIR: build DIR as TAG and copy it onto every node of the cluster
image() {
    docker build --quiet ${args[@]+"${args[@]}"} -t "$1" "$2" > /dev/null
    kind load docker-image --name "$CLUSTER" "$1" > /dev/null
    echo "loaded $1"
}

image nginx-devops/nginx:1.31.10 "$ROOT/labs/cloud-images/nginx"
# FROM the image above, so it comes second
image nginx-devops/nginx-acme:1.31.10 "$ROOT/labs/cloud-images/nginx-acme"
image nginx-devops/nginx-otel:1.31.10 "$ROOT/labs/cloud-images/nginx-otel"
image nginx-devops/nginx-ext:1.31.10 "$ROOT/labs/cloud-images/nginx-ext"
