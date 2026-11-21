#!/usr/bin/env bash
# Render every mermaid block of the given chapters with mermaid-cli; a syntax error fails.
#   tools/check_mermaid.sh ops/09-rate-limiting.md [more.md ...]
# Needs Node (npx downloads @mermaid-js/mermaid-cli and a headless Chromium on first use).
set -Eeuo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0
for md in "$@"; do
    n=$(grep -c '^```mermaid' "$md" || true)
    if npx -y @mermaid-js/mermaid-cli@11 -q -i "$md" -o "$tmp/out.md" >"$tmp/log" 2>&1; then
        echo "OK   $md: $n mermaid blocks"
    else
        echo "FAIL $md"
        grep -iE 'error|parse' "$tmp/log" | head -5 | sed 's/^/    /'
        rc=1
    fi
done
exit $rc
