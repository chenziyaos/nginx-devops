#!/bin/bash
. "$(dirname "$0")/../lib.sh"

step "Bad context: worker_processes in server block"
expect "is not allowed here" "$(t conf/bad-context.conf 2>&1 | grep -o 'is not allowed here')" "is not allowed here"

step "Bad arguments: listen with junk parameter"
expect "invalid parameter" "$(t conf/bad-args.conf 2>&1 | grep -o 'invalid parameter')" "invalid parameter"

step "Include with glob pattern"
start conf/with-include.conf
expect "main server responds" "$(code http://127.0.0.1:18040)" "200"
expect "included server 1 responds" "$(code http://127.0.0.1:18041)" "200"
expect "included server 2 responds" "$(code http://127.0.0.1:18042)" "200"
stop

step "Array override: add_header in location vs inherited"
start conf/inherit-array-override.conf
hdr_override="$(hdrs http://127.0.0.1:18045/ 'X-')"
hdr_inherited="$(hdrs http://127.0.0.1:18045/inherited 'X-')"
expect "location override: X-Child present" "$(echo "$hdr_override" | grep -c X-Child)" "1"
expect "location override: X-Parent absent" "$(echo "$hdr_override" | grep -c X-Parent)" "0"
expect "inherited location: X-Parent present" "$(echo "$hdr_inherited" | grep -c X-Parent)" "1"
stop

step "Array with add_header_inherit merge"
start conf/inherit-array-with-inherit.conf
hdr_merge="$(hdrs http://127.0.0.1:18046/ 'X-')"
hdr_on="$(hdrs http://127.0.0.1:18046/on 'X-')"
hdr_off="$(hdrs http://127.0.0.1:18046/off 'X-')"
hdr_off_no_header="$(hdrs http://127.0.0.1:18046/off-no-header 'X-')"
echo "$hdr_merge"
echo "$hdr_on"
echo "$hdr_off"
echo "$hdr_off_no_header"
expect "merge mode: X-Parent present" "$(echo "$hdr_merge" | grep -c X-Parent)" "1"
expect "merge mode: X-Child present" "$(echo "$hdr_merge" | grep -c X-Child)" "1"
expect "on mode: X-Child present" "$(echo "$hdr_on" | grep -c X-Child)" "1"
expect "on mode: X-Parent absent" "$(echo "$hdr_on" | grep -c X-Parent)" "0"
expect "off mode: X-Child present" "$(echo "$hdr_off" | grep -c X-Child)" "1"
expect "off mode: X-Parent absent" "$(echo "$hdr_off" | grep -c X-Parent)" "0"
expect "off-no-header mode: X-Parent absent" "$(echo "$hdr_off_no_header" | grep -c X-Parent)" "0"
expect "off-no-header mode: X-Child absent" "$(echo "$hdr_off_no_header" | grep -c X-Child)" "0"
stop

step "Variables: map directive"
start conf/map-vars.conf
result_default="$(get http://127.0.0.1:18047/?device=unknown)"
result_mobile="$(get http://127.0.0.1:18047/?device=mobile)"
result_tablet="$(get http://127.0.0.1:18047/?device=tablet)"
expect "map unknown case" "$(echo "$result_default" | tr -d '\n')" "device=unknown"
expect "map mobile case" "$(echo "$result_mobile" | tr -d '\n')" "device=phone"
expect "map tablet case" "$(echo "$result_tablet" | tr -d '\n')" "device=pad"
stop

step "if statement with add_header (may not work)"
start conf/if-problem.conf
# When test=yes, the if block adds X-IfTest but may lose X-Parent due to override
hdr_if_true="$(hdrs http://127.0.0.1:18048/?test=yes 'X-')"
# When test=no, the if doesn't trigger, so only X-Parent should appear
hdr_if_false="$(hdrs http://127.0.0.1:18048/?test=no 'X-')"
echo "With test=yes (if condition true):"
echo "$hdr_if_true"
echo "With test=no (if condition false):"
echo "$hdr_if_false"
# When if is true: should have both headers, but due to if creating implicit location, X-Parent might be missing
expect "if-true: X-IfTest present" "$(echo "$hdr_if_true" | grep -c 'X-IfTest')" "1"
# When if is false: X-Parent should appear (no override), X-IfTest should not
expect "if-false: X-Parent present" "$(echo "$hdr_if_false" | grep -c 'X-Parent')" "1"
expect "if-false: X-IfTest absent" "$(echo "$hdr_if_false" | grep -c 'X-IfTest')" "0"
stop

step "add_header with safe vs unsafe status codes"
start conf/status-code-safe.conf
# On 200 (safe status), both regular and always headers should appear
hdr_ok_full="$(hdrs http://127.0.0.1:18049/ok 'X-')"
# On 404 (unsafe status), only always header should appear
hdr_404_full="$(hdrs http://127.0.0.1:18049/notfound 'X-')"
echo "Status 200 headers:"
echo "$hdr_ok_full"
echo "Status 404 headers:"
echo "$hdr_404_full"
expect "200: X-Regular present" "$(echo "$hdr_ok_full" | grep -c 'X-Regular')" "1"
expect "200: X-Always present" "$(echo "$hdr_ok_full" | grep -c 'X-Always')" "1"
expect "404: X-Regular absent" "$(echo "$hdr_404_full" | grep -c 'X-Regular')" "0"
expect "404: X-Always present" "$(echo "$hdr_404_full" | grep -c 'X-Always')" "1"
stop

step "nginx -T: show merged configuration"
# Test the -T output with include expansion
T_output="$(ngx -t -c conf/for-T-output.conf 2>&1 || true)"
echo "Configuration test output:"
echo "$T_output"
# This is informational; just ensure -t works
expect "nginx -t success" "$(echo "$T_output" | grep -c 'successful')" "1"
