#!/usr/bin/env bash
# Create (or recreate) the kind cluster of the cloud-native labs, then build and load the
# lab images.
#
#   tools/cloud_up.sh                     # cluster "lab", Kubernetes 1.37.0
#   KIND_CLUSTER=other tools/cloud_up.sh
#
# Needs docker, kind (v0.33.0 was used) and kubectl. Proxy variables set in the environment
# are passed on by kind to the nodes and by tools/cloud_images.sh to docker build.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLUSTER=${KIND_CLUSTER:-lab}
NODE=kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5

kind delete cluster --name "$CLUSTER" > /dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --config "$ROOT/labs/cloud-images/kind.yaml" --image "$NODE" --wait 300s
kubectl wait --for=condition=Ready nodes --all --timeout=180s > /dev/null
"$ROOT/tools/cloud_images.sh"
