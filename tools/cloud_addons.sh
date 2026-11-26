#!/usr/bin/env bash
# Install what the Gateway API labs (cloud-03 and later) need on top of tools/cloud_up.sh:
# the Gateway API CRDs, NGINX Gateway Fabric, and the ingress2gateway binary.
#
#   tools/cloud_addons.sh            # idempotent: helm upgrade --install, kubectl apply
#
# Versions are pinned below. Downloads go through the proxy variables of the environment.
# ingress2gateway lands in .cloud-tools/bin (not in git); labs/cloud-lib.sh puts it on PATH.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATEWAY_API=v1.7.0
NGF=2.9.1
I2G=v1.2.0
I2G_SHA256=9aaef850521a6b217bc358fc2267429629990dfe624ede601178c73f32ccad6d   # Linux x86_64

ctx=$(kubectl config current-context)
[[ "$ctx" == kind-* ]] || { echo "refusing to install into context $ctx (not kind-*)" >&2; exit 2; }

kubectl apply --server-side -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API/standard-install.yaml" > /dev/null
echo "Gateway API $GATEWAY_API CRDs applied"

# The data plane Service is a ClusterIP: kind has no load balancer, and the labs send
# their requests from a pod inside the cluster.
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version "$NGF" \
    --namespace nginx-gateway --create-namespace \
    --set nginx.service.type=ClusterIP \
    --wait --timeout 5m > /dev/null
echo "NGINX Gateway Fabric $NGF installed in namespace nginx-gateway"

bin="$ROOT/.cloud-tools/bin"
mkdir -p "$bin"
if [[ ! -x "$bin/ingress2gateway" ]] || ! "$bin/ingress2gateway" version 2>/dev/null | grep -q "$I2G"; then
    tmp=$(mktemp -d)
    curl -fsSLo "$tmp/i2g.tar.gz" \
        "https://github.com/kubernetes-sigs/ingress2gateway/releases/download/$I2G/ingress2gateway_Linux_x86_64.tar.gz"
    echo "$I2G_SHA256  $tmp/i2g.tar.gz" | sha256sum -c - > /dev/null
    tar -xzf "$tmp/i2g.tar.gz" -C "$tmp" ingress2gateway
    mv "$tmp/ingress2gateway" "$bin/ingress2gateway"
    rm -rf "${tmp:?}"
fi
echo "ingress2gateway $I2G in .cloud-tools/bin"
