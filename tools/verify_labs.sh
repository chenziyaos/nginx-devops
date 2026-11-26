#!/usr/bin/env bash
# Run labs and compare their output with the expected.txt that the chapters quote.
#
#   tools/verify_labs.sh              # every lab
#   tools/verify_labs.sh ops-05 dev   # labs whose name starts with one of the arguments
#   UPDATE=1 tools/verify_labs.sh ops-05   # rewrite expected.txt from the current output
#
# Exit code 1 if any lab fails or differs. Output lives in labs/<id>/out/actual.txt.
# A lab that exits with 77 cannot run here (the cloud-* labs need a kind cluster); it is
# reported as SKIP and counted separately, never as a match.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
pass=0
fail=0
skip=0

labs=()
for d in "$ROOT"/labs/*/; do
    id=$(basename "$d")
    [[ -f "$d/run.sh" ]] || continue
    if (( $# == 0 )); then
        labs+=("$id")
        continue
    fi
    for a in "$@"; do
        if [[ "$id" == "$a"* ]]; then
            labs+=("$id")
            break
        fi
    done
done

for id in ${labs[@]+"${labs[@]}"}; do
    d="$ROOT/labs/$id"
    mkdir -p "$d/out"
    rc=0
    bash "$d/run.sh" > "$d/out/actual.txt" 2> "$d/out/stderr.txt" || rc=$?
    if (( rc == 77 )); then
        echo "SKIP $id: $(tail -1 "$d/out/stderr.txt")"
        skip=$((skip + 1))
        continue
    fi
    if (( rc != 0 )); then
        echo "FAIL $id: run.sh exited $rc"
        tail -5 "$d/out/stderr.txt" | sed 's/^/    /'
        fail=$((fail + 1))
        continue
    fi
    if grep -q '^NOT OK' "$d/out/actual.txt"; then
        echo "FAIL $id: a claim does not hold"
        grep '^NOT OK' "$d/out/actual.txt" | head -10 | sed 's/^/    /'
        fail=$((fail + 1))
        continue
    fi
    if [[ -n "${UPDATE:-}" ]]; then
        cp "$d/out/actual.txt" "$d/expected.txt"
        echo "UPDATED $id"
        pass=$((pass + 1))
        continue
    fi
    if diff -u "$d/expected.txt" "$d/out/actual.txt" > "$d/out/diff.txt"; then
        echo "PASS $id"
        pass=$((pass + 1))
    else
        echo "FAIL $id: output differs from expected.txt"
        head -20 "$d/out/diff.txt" | sed 's/^/    /'
        fail=$((fail + 1))
    fi
done

if (( skip )); then
    echo "$pass/$((pass + fail)) labs match, $skip skipped"
else
    echo "$pass/$((pass + fail)) labs match"
fi
(( fail == 0 ))
