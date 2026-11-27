# cloud-05 hypotheses (from the source of nginx 1.31.10, nginx-acme 0.4.2, pebble 2.10.3, cert-manager 1.21.3 and NGF 2.9.1)

pebble runs in the lab namespace with a profile `short` of 120 s, random sleeps off, nonce
rejection off, and valid authorizations always reused. nginx-acme is built as a dynamic
module against the configure arguments of the base image.

1. The module image and the base image report the same configure arguments, and nginx loads
   the module without an emerg (a dynamic module from other arguments is refused as not
   binary compatible).
2. acme-a orders the certificate of its server_name. pebble validates HTTP-01 with three
   concurrent requests and all three must pass (va/va.go:47, 276-283); the module answers
   them from shared memory (src/acme/solvers/http.rs:101-111). The certificate is valid
   from NotBefore to NotBefore + 120 s - 1 s (ca/ca.go:301): 119 s.
3. Worker 0 runs the renewal loop (src/lib.rs:156-160, 194-206). A renewal rewrites the
   chain and key in shared memory in place (src/state/certificate.rs:219-235), and
   `$acme_certificate` returns the new value at the next handshake (src/variables.rs:36-65).
   The serial changes within the lifetime; no SIGHUP, the same worker.
4. acme-b, the same config, is not behind the Service of the name. Its token is only in its
   own shared zone (src/acme/solvers/http.rs:71-77), pebble's three requests go to acme-a,
   which declines and answers 404 from `location /`. acme-b's order fails (warn with
   "returned 404") and it has no certificate: `$acme_certificate` is not found, the empty
   path resolves to the conf prefix, the handshake fails (curl exit 35).
5. cert-manager solves HTTP-01 with an HTTPRoute on the Gateway's http listener. It checks
   the URL itself five times, two seconds apart, before it tells the CA
   (pkg/issuer/acme/http/http.go:88, 172-181), then pebble's three requests. The Secret
   web-tls is kubernetes.io/tls with tls.crt and tls.key; the HTTPS listener serves it.
6. A renewal (an Issuing condition, as `cmctl renew` sets it) writes a new certificate and,
   with the default rotation policy Always (internal/apis/certmanager/v1/defaults.go:58),
   a new key. In a pod that mounts the Secret, a server with a plain path keeps what it
   loaded at start; a server whose path contains a variable loads the file at every
   handshake (ngx_http_request.c:1043-1095) and serves the new one. A reload makes the
   plain path load it.
7. NGF 2.9 writes the paths as `$dynamic_cert_prefix/etc/nginx/secrets/...` with a map that
   is always "" (maps.go:39-45), and sends a Secret-only change as a ContentUpdateRequest,
   which does not reload (deployment.go:574-588). With the cache it sets
   (ssl_certificate_cache, entries valid 60 s by default) nginx stats the file again when
   an entry is older than that (ngx_event_openssl_cache.c:345-365): the Gateway serves the
   new certificate with no SIGHUP.
