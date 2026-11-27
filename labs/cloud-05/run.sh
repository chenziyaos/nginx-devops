# cloud-05: certificates in the cluster, from pebble (the test ACME server of Let's Encrypt).
# nginx-acme orders and renews inside nginx; cert-manager writes a Secret that a plain nginx
# and NGINX Gateway Fabric read. Needs tools/cloud_addons.sh and the nginx-acme image of
# tools/cloud_images.sh. Expected values come from the source (HYPOTHESES.md).
. "$(dirname "$0")/../cloud-lib.sh"

DOMAIN=web.$NS.svc.cluster.local
GW_DOMAIN=gw-nginx.$NS.svc.cluster.local

# a CA and pebble's serving certificate: the one pebble ships is for localhost
mkdir -p out/run/ca
(
    cd out/run/ca
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
        -subj "/CN=$NS ca" -keyout ca.key -out ca.crt 2> /dev/null
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -subj /CN=pebble -keyout tls.key -out tls.csr 2> /dev/null
    printf 'subjectAltName=DNS:pebble.%s.svc.cluster.local\n' "$NS" > san.ext
    openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 \
        -extfile san.ext -out tls.crt 2> /dev/null
)
k create secret generic pebble-tls --from-file=out/run/ca/ca.crt --from-file=out/run/ca/tls.crt \
    --from-file=out/run/ca/tls.key > /dev/null
conf pebble-conf conf/pebble.json
apply k8s/pebble.yaml
client
ready app=pebble

until_ok() {
    local end=$(( $(date +%s) + $1 ))
    shift
    until "$@" > /dev/null 2>&1; do
        (( $(date +%s) < end )) || { echo "timed out: $*" >&2; return 1; }
        sleep 0.5
    done
}
addr() { k get pod "$1" -o jsonpath='{.status.podIP}'; }
# certinfo IP PORT NAME: curl's view of the certificate served at IP:PORT for SNI NAME
certinfo() {
    kx client curl -sk --max-time 5 -o /dev/null -w '%{certs}' \
        --resolve "$3:$2:$1" "https://$3:$2/" 2> /dev/null || true
}
# hex: a serial number in lower case, without colons and leading zeros
hex() { tr -d ':' | tr 'A-F' 'a-f' | sed 's/^0*//'; }
# serial IP PORT NAME: the serial of the certificate served there, empty if the handshake fails
serial() { certinfo "$@" | sed -n 's/^Serial Number://p' | head -1 | hex; }
# fileserial: the serial of the PEM certificate on stdin
fileserial() { openssl x509 -noout -serial | sed 's/^serial=//' | hex; }
secretserial() { k get secret web-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | fileserial; }
# sn SERIAL: S1, S2, ... in the order serials first appear in this run; "none" when empty
sn() {
    [[ -n "$1" ]] || { echo none; return; }
    grep -qx "$1" out/run/serials 2> /dev/null || echo "$1" >> out/run/serials
    echo "S$(grep -nx "$1" out/run/serials | cut -d: -f1)"
}
# lifetime IP PORT NAME: NotAfter - NotBefore of the certificate served there, in seconds
lifetime() {
    certinfo "$@" | awk '/^Start date:/ && !a { a = substr($0, 12) } /^Expire date:/ && !e { e = substr($0, 13) }
        END { print a "|" e }' | {
        IFS='|' read -r a e
        echo $(( $(date -d "$e" +%s) - $(date -d "$a" +%s) ))
    }
}
workers() { kx "$1" ps -eo pid,args | awk '/nginx: worker process$/ { print $1 }' | sort | tr '\n' ' '; }
sighups() { k logs "$@" | grep -ac 'signal 1 (SIGHUP) received' || true; }

conf acme-conf conf/acme.conf
apply k8s/acme.yaml
ready app=acme

step "an image with the module"
kx acme-a nginx -V 2>&1 | sed -n 's/^configure arguments: //p' > out/run/args-acme.txt
kx client nginx -V 2>&1 | sed -n 's/^configure arguments: //p' > out/run/args-base.txt
echo "configure arguments of the module image and the base image: $(cmp -s out/run/args-acme.txt out/run/args-base.txt && echo same || echo different)"
kx acme-a ls -l /usr/lib/nginx/modules | awk 'NR > 1 { print $NF }'
head -3 conf/acme.conf | tail -1
until_ok 60 eval "k logs acme-a | grep -q 'start worker process'"
echo "acme-a: $(k logs acme-a | grep -ac 'emerg') emerg lines, $(k logs acme-a | grep -ac 'start worker process [0-9]') worker started"
expect "nginx loads the module built against its own configure arguments" \
    "$(cmp -s out/run/args-acme.txt out/run/args-base.txt && echo same) $(k logs acme-a | grep -ac 'emerg')" "same 0"

step "a certificate over HTTP-01"
until_ok 60 eval "k logs acme-a | grep -q 'certificate issued'"
k logs acme-a | grep -a 'LetsEncrypt-Pebble-VA' | awk '$9 == 200 { print $6, $7, $9 }' > out/run/va-a.txt
echo "pebble's requests answered by acme-a: $(wc -l < out/run/va-a.txt), for $(awk '{ print $2 }' out/run/va-a.txt | sort -u | wc -l) token"
sed -E 's|/acme-challenge/[^ ]+|/acme-challenge/<token>|' out/run/va-a.txt | sort -u
k logs acme-a | grep -a 'certificate issued' | head -1 \
    | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /; s/at [0-9TZ:-]+/at <time>/'
s1=$(serial "$(addr acme-a)" 443 "$DOMAIN")
echo "acme-a serves $(sn "$s1"), issuer: $(certinfo "$(addr acme-a)" 443 "$DOMAIN" | sed -n 's/^Issuer:CN = //p' | head -1 | sed 's/ [0-9a-f]*$//'), NotAfter - NotBefore: $(lifetime "$(addr acme-a)" 443 "$DOMAIN") s"
expect "pebble asks three times and acme-a answers each; the certificate lives 120 s minus one" \
    "$(wc -l < out/run/va-a.txt) $(sn "$s1") $(lifetime "$(addr acme-a)" 443 "$DOMAIN")" "3 S1 119"

step "a renewal without a reload"
w0=$(workers acme-a)
echo "workers of acme-a before: $( [[ -n "$w0" ]] && echo "$(wc -w <<< "$w0")" )"
until_ok 180 eval "[[ -n \$(serial $(addr acme-a) 443 $DOMAIN) && \$(serial $(addr acme-a) 443 $DOMAIN) != $s1 ]]"
s2=$(serial "$(addr acme-a)" 443 "$DOMAIN")
echo "acme-a serves $(sn "$s2") now"
k logs acme-a | grep -a 'certificate issued' | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /; s/at [0-9TZ:-]+/at <time>/; s/, acme issuer.*//'
echo "same worker processes: $( [[ "$(workers acme-a)" == "$w0" ]] && echo yes || echo no), SIGHUP received: $(sighups acme-a)"
expect "the module replaces the certificate in shared memory; no process restarts" \
    "$(sn "$s2") $( [[ "$(workers acme-a)" == "$w0" ]] && echo same) $(sighups acme-a)" "S2 same 0"

step "a second replica's challenge goes to the first"
until_ok 60 eval "k logs acme-b | grep -q 'returned 404'"
tok=$(k logs acme-b | grep -a 'returned 404' | head -1 | sed -E 's|.*/acme-challenge/([^ ]+) returned.*|\1|')
k logs acme-b | grep -a 'returned 404' | head -1 \
    | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: /\1 /; s|/acme-challenge/[^ ]+|/acme-challenge/<token>|; s/, acme issuer.*//'
echo "requests for that token in the log of acme-a: $(k logs acme-a | grep -a "$tok" | awk '{ print $9 }' | sort | uniq -c | awk '{ print $1 " x " $2 }'), of acme-b: $(k logs acme-b | grep -a "GET /.well-known/acme-challenge/$tok" -c)"
rc=0
kx client curl -sk --max-time 5 -o /dev/null --resolve "$DOMAIN:443:$(addr acme-b)" "https://$DOMAIN/" 2> /dev/null || rc=$?
echo "curl to acme-b over TLS: exit $rc"
k logs acme-b | grep -a 'cannot load certificate' | head -1 \
    | sed -E 's/^[0-9\/]+ [0-9:]+ (\[[a-z]+\]) [0-9]+#[0-9]+: \*[0-9]+ /\1 /; s/, client:.*//'
expect "pebble's three requests for acme-b's token reach acme-a and get 404; acme-b has no certificate" \
    "$(k logs acme-a | grep -a "$tok" | awk '$9 == 404' | wc -l) $(k logs acme-b | grep -a "GET /.well-known/acme-challenge/$tok" -c) $rc" "3 0 35"

gwserial() { serial "$(k get svc gw-nginx -o jsonpath='{.spec.clusterIP}')" 443 "$GW_DOMAIN"; }
# challenge UA: pebble's and cert-manager's requests for the challenge in gw-nginx's log
challenge() {
    k logs deploy/gw-nginx -c nginx | grep -a 'acme-challenge' | awk -F'"' '{ split($3, a, " "); print $6, a[1] }' \
        | sed -E 's|^(cert-manager-challenges)/[^ ]+ .* ([0-9]+)$|\1 \2|; s|^(LetsEncrypt-Pebble-VA) .* ([0-9]+)$|\1 \2|' \
        | grep " 200$" | sort | uniq -c | awk '{ print "  " $2 ": " $1 " x " $3 }'
}
conf app-conf conf/app.conf
apply k8s/gateway.yaml
k rollout status deploy/gw-nginx --timeout=180s > /dev/null
ready app=app

step "cert-manager orders through the Gateway"
sed "s|CA_BUNDLE|$(base64 -w0 < out/run/ca/ca.crt)|" k8s/cert.yaml | k apply -f - > /dev/null
k wait --for=condition=Ready certificate/web-tls --timeout=180s > /dev/null
echo "Certificate web-tls: Ready=$(k get certificate web-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'), revision $(k get certificate web-tls -o jsonpath='{.status.revision}')"
echo "requests for the challenge in the log of gw-nginx, answered 200:"
challenge
echo "HTTPRoutes left: $(k get httproute -o name | tr '\n' ' ')"
echo "Secret web-tls: type $(k get secret web-tls -o jsonpath='{.type}'), keys $(k get secret web-tls -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
s3=$(secretserial)
until_ok 60 eval '[[ $(gwserial) == $s3 ]]'
echo "Secret holds $(sn "$s3"), the Gateway serves $(sn "$(gwserial)")"
expect "cert-manager checks five times itself, pebble three times; the HTTPS listener serves the Secret" \
    "$(challenge | tr -s ' ' | tr '\n' ' ')$(sn "$(gwserial)")" \
    " LetsEncrypt-Pebble-VA: 3 x 200  cert-manager-challenges: 5 x 200 S3"

step "a renewal changes the Secret, not what nginx serves"
conf tls-conf conf/tls.conf
apply k8s/tls.yaml
ready app=tls
echo "tls serves on 443 (plain path) $(sn "$(serial "$(addr tls)" 443 "$GW_DOMAIN")"), on 8443 (variable path) $(sn "$(serial "$(addr tls)" 8443 "$GW_DOMAIN")")"
key0=$(k get secret web-tls -o jsonpath='{.data.tls\.key}' | md5sum)
gw0=$(sighups deploy/gw-nginx -c nginx)
# what `cmctl renew` does: an Issuing condition in the Certificate's status
k patch certificate web-tls --subresource=status --type=json -p '[{"op": "add", "path": "/status/conditions/-",
    "value": {"type": "Issuing", "status": "True", "reason": "ManuallyTriggered", "message": "lab renewal"}}]' > /dev/null
until_ok 120 eval '[[ -n $(secretserial) && $(secretserial) != $s3 ]]'
t4=$(date +%s)
s4=$(secretserial)
echo "Secret holds $(sn "$s4"), revision $(k get certificate web-tls -o jsonpath='{.status.revision}'), private key replaced: $( [[ $(k get secret web-tls -o jsonpath='{.data.tls\.key}' | md5sum) != "$key0" ]] && echo yes || echo no)"
# a changed annotation makes kubelet sync the pod's volumes now, not within 90 s (cloud-04)
k annotate pod tls lab/sync="$(date +%s%N)" --overwrite > /dev/null
until_ok 60 eval '[[ $(kx tls cat /etc/tls/tls.crt | fileserial) == $s4 ]]'
echo "file in the pod: $(sn "$(kx tls cat /etc/tls/tls.crt | fileserial)"), 443: $(sn "$(serial "$(addr tls)" 443 "$GW_DOMAIN")"), 8443: $(sn "$(serial "$(addr tls)" 8443 "$GW_DOMAIN")")"
expect "the plain path keeps the certificate it loaded; the variable path reads the new file" \
    "$(sn "$(serial "$(addr tls)" 443 "$GW_DOMAIN")") $(sn "$(serial "$(addr tls)" 8443 "$GW_DOMAIN")")" "S3 S4"
kx tls nginx -c /etc/nginx/conf/tls.conf -s reload 2> /dev/null
until_ok 30 eval '[[ $(serial $(addr tls) 443 $GW_DOMAIN) == $s4 ]]'
echo "after nginx -s reload, 443: $(sn "$(serial "$(addr tls)" 443 "$GW_DOMAIN")")"
expect "a reload loads the new file" "$(sn "$(serial "$(addr tls)" 443 "$GW_DOMAIN")")" "S4"

step "the Gateway picks it up without a reload"
until_ok 90 eval '[[ $(gwserial) == $s4 ]]'
# seconds from the Secret change to the Gateway serving it: not printed, it depends on
# the 60 s ssl_certificate_cache and on when the handshakes come
echo $(( $(date +%s) - t4 )) > out/run/gw-delay.txt
echo "gw-nginx serves $(sn "$(gwserial)"), SIGHUPs since the renewal: $(( $(sighups deploy/gw-nginx -c nginx) - gw0 ))"
gwx() { k exec deploy/gw-nginx -c nginx -- "$@"; }
gwx sh -c "grep -h 'ssl_certificate' /etc/nginx/conf.d/*.conf | sort -u | sed 's/^ *//'"
expect "NGF only rewrites the file; the variable in the path makes nginx read it again" \
    "$(sn "$(gwserial)") $(( $(sighups deploy/gw-nginx -c nginx) - gw0 ))" "S4 0"
