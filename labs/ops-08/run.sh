# ops-08: TLS protocols, certificates and SNI, session tickets across reload, HTTP/2, HTTP/3.
# Expected values come from the source (see HYPOTHESES.md).
. "$(dirname "$0")/../lib.sh"

# an OpenSSL 3 command line client; the system curl on macOS cannot do TLSv1.3 or QUIC
OPENSSL=${OPENSSL:-$( (command -v brew > /dev/null && echo "$(brew --prefix openssl@3)/bin/openssl") || command -v openssl)}
ssl() { "$OPENSSL" "$@"; }

# a throwaway CA and three certificates in out/run/
O=out/run
ssl req -x509 -newkey rsa:2048 -nodes -keyout $O/ca.key -out $O/ca.crt -days 2 -subj /CN=lab-ca 2> /dev/null
issue() {   # issue NAME CN KEYTYPE
    if [[ $3 == ec ]]; then
        ssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $O/$1.key -out $O/$1.csr -subj "/CN=$2" 2> /dev/null
    else
        ssl req -newkey rsa:2048 -nodes -keyout $O/$1.key -out $O/$1.csr -subj "/CN=$2" 2> /dev/null
    fi
    printf 'subjectAltName=DNS:%s\n' "$2" > $O/$1.ext
    ssl x509 -req -in $O/$1.csr -CA $O/ca.crt -CAkey $O/ca.key -CAcreateserial -days 2 -extfile $O/$1.ext -out $O/$1.crt 2> /dev/null
}
issue a-rsa a.test rsa
issue a-ec a.test ec
issue b b.test rsa

# hs PORT [s_client args...]: one handshake, then the lines that describe it
hs() {
    local port=$1; shift
    ssl s_client -connect 127.0.0.1:$port -CAfile $O/ca.crt "$@" < /dev/null > $O/hs.txt 2>&1 || true
}
field() { grep -m1 -E "$1" $O/hs.txt | sed -E 's/^ +//' || true; }

start

step "default protocols"
for p in tls1_3 tls1_2 tls1_1; do
    hs 18160 -servername a.test -$p -cipher 'DEFAULT@SECLEVEL=0'
    printf '%-8s %s\n' "$p" "$(field '^ *Protocol *:|^New, ' | sed 's/, Cipher is.*//') $(grep -q 'no peer certificate available' $O/hs.txt && echo '(handshake failed)')"
done
sleep 0.2
errlog 'unsupported protocol' | sed -E 's/\*[0-9]+ //; s/\(SSL: error:[0-9A-F]+:SSL routines::/(SSL: /; s/, client: .*//' | head -1
expect "TLSv1.2 and TLSv1.3 are accepted; TLSv1.1 is refused by the server" \
    "$(hs 18160 -servername a.test -tls1_1 -cipher 'DEFAULT@SECLEVEL=0'; grep -c 'no peer certificate available' $O/hs.txt) $(errlog 'unsupported protocol' | wc -l | tr -d ' ' | sed 's/^[1-9][0-9]*$/logged/')" \
    "1 logged"

step "RSA and ECDSA certificates on one server"
hs 18160 -servername a.test -tls1_3 -sigalgs 'rsa_pss_rsae_sha256'
echo "client accepts RSA-PSS only: $(field 'Server public key is') / $(field 'Peer signature type')"
hs 18160 -servername a.test -tls1_3 -sigalgs 'ecdsa_secp256r1_sha256'
echo "client accepts ECDSA only:   $(field 'Server public key is') / $(field 'Peer signature type')"
expect "OpenSSL picks the certificate that matches the client's signature algorithms" \
    "$(hs 18160 -servername a.test -tls1_3 -sigalgs rsa_pss_rsae_sha256; field 'Server public key is') $(hs 18160 -servername a.test -tls1_3 -sigalgs ecdsa_secp256r1_sha256; field 'Server public key is')" \
    "Server public key is 2048 bit Server public key is 256 bit"

step "SNI and the default server"
for n in a.test b.test other.test; do
    hs 18160 -servername $n
    printf '18160 SNI %-10s -> %s, %s\n' "$n" "$(field '^subject=')" "$(field 'Verify return code')"
done
for n in a.test other.test; do
    hs 18161 -servername $n
    printf '18161 SNI %-10s -> %s\n' "$n" "$(field '^subject=|unrecognized name' | sed -E 's/.*(tlsv1 unrecognized name).*(SSL alert number [0-9]+).*/\1, \2/')"
done
expect "an unknown name gets the default server's certificate, or nothing with ssl_reject_handshake" \
    "$(hs 18160 -servername other.test; field '^subject=') | $(hs 18161 -servername other.test; grep -c 'tlsv1 unrecognized name' $O/hs.txt)" \
    "subject=CN=a.test | 1"
errlog 'handshake rejected' | sed -E 's/\*[0-9]+ //; s/, client: .*//' | head -1

step "plain HTTP to an HTTPS port"
curl -s http://127.0.0.1:18160/ | grep -m1 -o 'The plain HTTP request was sent to HTTPS port'
echo "status: $(code http://127.0.0.1:18160/)"
expect "nginx answers 400 with its own message (497 inside, for error_page)" \
    "$(code http://127.0.0.1:18160/) $(curl -s http://127.0.0.1:18160/ | grep -q 'plain HTTP request was sent to HTTPS port' && echo yes)" "400 yes"
echo "with error_page 497 =301: $(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: a.test' 'http://127.0.0.1:18163/x?y=1')"
expect "error_page 497 turns the same request into a redirect to https" \
    "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: a.test' 'http://127.0.0.1:18163/x?y=1')" \
    "301 https://a.test:18163/x?y=1"

step "certificates loaded per handshake"
mkdir -p $O/dyn
cp $O/a-rsa.crt $O/dyn/a.test.crt; cp $O/a-rsa.key $O/dyn/a.test.key
for p in 18167 18168; do hs $p -servername a.test; echo "$p a.test, first:            $(field '^subject=')"; done
# the file now holds b.test's certificate
cp $O/b.crt $O/dyn/a.test.crt; cp $O/b.key $O/dyn/a.test.key
for p in 18167 18168; do hs $p -servername a.test; echo "$p a.test, file replaced:    $(field '^subject=')"; done
hs 18167
echo "18167 no SNI:                   $(field 'no peer certificate available|^subject=')"
sleep 0.2
errlog 'cannot load certificate' | sed -E "s#$LAB/#\$LAB/#g" | sed -E 's/\*[0-9]+ //; s/ \(SSL: .*//; s/, client: .*//' | head -1
expect "without a cache every handshake reads the file; ssl_certificate_cache keeps the old one for valid=60s" \
    "$(hs 18167 -servername a.test; field '^subject=') | $(hs 18168 -servername a.test; field '^subject=')" \
    "subject=CN=b.test | subject=CN=a.test"

step "session tickets and reload"
resume() {   # resume PORT: "New" or "Reused" for a second handshake with the saved session
    ssl s_client -connect 127.0.0.1:$1 -tls1_2 -CAfile $O/ca.crt -sess_in $O/sess.$1 < /dev/null 2> /dev/null \
        | grep -m1 -oE '^(New|Reused)' || true
}
for p in 18162 18163; do
    ssl s_client -connect 127.0.0.1:$p -tls1_2 -CAfile $O/ca.crt -sess_out $O/sess.$p < /dev/null > /dev/null 2>&1 || true
done
before="$(resume 18162) $(resume 18163)"
echo "before reload: no cache: $(resume 18162), shared cache: $(resume 18163)"
reload
after="$(resume 18162) $(resume 18163)"
echo "after reload:  no cache: $(resume 18162), shared cache: $(resume 18163)"
expect "ticket keys of a shared session cache survive a reload, the SSL_CTX ones do not" \
    "$before | $after" "Reused Reused | New Reused"

step "HTTP/2"
echo "TLS, http2 on:       $(curl -sk --http2 https://127.0.0.1:18160/proto)"
echo "TLS, no http2:       $(curl -sk --http2 https://127.0.0.1:18162/proto -o /dev/null -w '%{http_version}' | sed 's/^/HTTP\//')"
echo "plain, http2 on:     $(curl -s --http2-prior-knowledge http://127.0.0.1:18164/proto)"
echo "plain, no http2:     $(curl -s --http2-prior-knowledge http://127.0.0.1:18165/proto -o /dev/null -w '%{http_code}' || true)"
preface() {   # preface PORT: what nginx sends back to the HTTP/2 connection preface, decoded
    python3 - "$1" <<'PY'
import socket, struct, sys, time
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])))
s.sendall(b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n')
time.sleep(0.2)
data = s.recv(4096)
if not data.startswith(b'\x00'):
    print(data.split(b'\r\n')[0].decode())
    sys.exit()
out = []
while len(data) >= 9:
    length = int.from_bytes(data[:3], 'big')
    ftype, body, data = data[3], data[9:9 + length], data[9 + length:]
    if ftype == 4:
        out.append('SETTINGS ' + ' '.join('%d=%d' % struct.unpack('>HI', body[i:i + 6])
                                          for i in range(0, len(body), 6)))
    elif ftype == 8:
        out.append('WINDOW_UPDATE %d' % (int.from_bytes(body, 'big') & 0x7fffffff))
print(' | '.join(out))
PY
}
echo "preface to 18165:    $(preface 18165)"
echo "preface to 18164:    $(preface 18164)"
# ngx_http_v2_send_settings: max streams 128, initial window = http2_body_preread_size 65536,
# max frame (1 << 24) - 1, NO_RFC7540_PRIORITIES 1; then the connection window is raised
# from 65535 to (1 << 31) - 1
expect "the SETTINGS frame carries the defaults from the source, and RFC 7540 priorities are switched off" \
    "$(preface 18164)" "SETTINGS 3=128 4=65536 5=$(( (1 << 24) - 1 )) 9=1 | WINDOW_UPDATE $(( (1 << 31) - 1 - 65535 ))"
t conf/listen-http2.conf | grep deprecated
expect "ALPN gives HTTP/2 only where http2 is on; listen ... http2 is deprecated" \
    "$(curl -sk --http2 https://127.0.0.1:18160/proto -o /dev/null -w '%{http_version}') $(curl -sk --http2 https://127.0.0.1:18162/ -o /dev/null -w '%{http_version}') $(t conf/listen-http2.conf | grep -c 'is deprecated')" \
    "2 1.1 1"

step "HTTP/3"
hs 18160 -quic -alpn h3 -servername a.test
echo "QUIC handshake: $(field '^ *Protocol *:|^New, ' | sed 's/, Cipher is.*//'), $(field 'ALPN protocol')"
curl -sk -D - -o /dev/null https://127.0.0.1:18160/ | tr -d '\r' | grep -i '^alt-svc'
expect "the QUIC listener negotiates h3; Alt-Svc comes from add_header" \
    "$(hs 18160 -quic -alpn h3 -servername a.test; field 'ALPN protocol') | $(curl -sk -D - -o /dev/null https://127.0.0.1:18160/ | tr -d '\r' | sed -n 's/^[Aa]lt-[Ss]vc: //p')" \
    'ALPN protocol: h3 | h3=":18160"; ma=86400'

stop
