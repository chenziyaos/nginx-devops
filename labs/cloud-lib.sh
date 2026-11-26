# Shared helpers for the cloud-native labs, labs/cloud-NN/run.sh. Source it first:
#   . "$(dirname "$0")/../cloud-lib.sh"
#
# These labs run against a local kind cluster (tools/cloud_images.sh loads the images).
# Every lab owns the namespace lab-cloud-NN: it is deleted and recreated at the start and
# deleted again on exit. The output format (## step, ok - claim) is the one of lib.sh, so
# tools/verify_labs.sh and tools/check_docs.py treat both kinds of labs the same way.
set -Eeuo pipefail

LAB=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)
ROOT=$(cd "$LAB/../.." && pwd)
NS=lab-$(basename "$LAB")
IMAGE=nginx-devops/nginx:1.31.10
PATH=$ROOT/.cloud-tools/bin:$PATH   # tools/cloud_addons.sh installs ingress2gateway here
cd "$LAB"

# Refuse to touch anything but a kind cluster. Exit code 77 makes verify_labs.sh report SKIP.
ctx=$(kubectl config current-context 2>/dev/null || true)
if [[ "$ctx" != kind-* ]]; then
    echo "SKIP: needs kubectl with a kind-* context (current: ${ctx:-none})" >&2
    exit 77
fi

rm -rf out/run
mkdir -p out/run

# k ARGS...: kubectl in the lab namespace
k() { kubectl -n "$NS" "$@"; }

ns_down() {
    kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=180s > /dev/null
}

ns_down
kubectl create namespace "$NS" > /dev/null
trap ns_down EXIT

# step "title": a section marker; chapters quote the output between markers.
step() { printf '\n## %s\n' "$*"; }

# expect "claim" ACTUAL WANTED: see lib.sh. Write WANTED from the source before running.
expect() {
    if [[ "$2" == "$3" ]]; then
        echo "ok - $1"
    else
        echo "NOT OK - $1: got [$2], want [$3]"
    fi
}

# expect_match "claim" ACTUAL REGEX: like expect, but WANTED is an extended regex.
expect_match() {
    if [[ "$2" =~ $3 ]]; then
        echo "ok - $1"
    else
        echo "NOT OK - $1: got [$2], want /$3/"
    fi
}

# conf NAME FILE...: (re)create ConfigMap NAME from the given files of the lab directory
conf() {
    local name=$1 args=() f
    shift
    for f in "$@"; do args+=(--from-file="$f"); done
    k create configmap "$name" "${args[@]}" --dry-run=client -o yaml | k apply -f - > /dev/null
}

# apply FILE...: kubectl apply the given manifests of the lab directory
apply() {
    local f
    for f in "$@"; do k apply -f "$f" > /dev/null; done
}

# ready SELECTOR: wait until every pod matching the label selector is Ready
ready() { k wait --for=condition=Ready pod -l "$1" --timeout=180s > /dev/null; }

# client: start the pod "client" (the lab image running a shell that exits on TERM), so
# requests come from inside the cluster
client() {
    k run client --image="$IMAGE" --restart=Never --labels=app=client \
        --command -- sh -c 'trap "exit 0" TERM; sleep infinity & wait' > /dev/null
    ready app=client
}

# kx POD CMD...: run CMD in POD
kx() { local pod=$1; shift; k exec "$pod" -- "$@"; }

# pods SELECTOR: names of the pods matching the selector, sorted
pods() { k get pods -l "$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }
