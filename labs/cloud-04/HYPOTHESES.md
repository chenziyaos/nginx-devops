# cloud-04 hypotheses (from the source and Kubernetes behavior, before running)

Two pods mount the ConfigMap `web-conf` (one key, nginx.conf) as a directory and start
nginx with `-c` on it and `-l unix:/run/ctl/nginx.sock` (control API, 1.31.5+). `plain` has
only nginx; `web` adds a sidecar that calls `PATCH /1/control/config` over the shared socket
whenever the ConfigMap volume changes.

1. kubelet writes a ConfigMap volume as a timestamped directory plus symlinks:
   `..data -> ..<timestamp>` and `nginx.conf -> ..data/nginx.conf`; an update writes a new
   directory and swaps `..data`, so the files change together.
2. An update reaches a directory mount at the pod's next kubelet sync, which can take up to
   the sync period (1 minute by default) plus the cache delay: measured once by hand, 77 s.
   The same key mounted with subPath is a bind mount of the file at pod start and is never
   updated. Changing a pod annotation makes kubelet sync that pod at once (0.4 s by hand);
   the later steps use it so they do not wait a minute each.
3. nginx does not watch its files: after the update it still answers with the old config.
   With the control API on, nginx keeps the text of every file it loaded
   (ngx_conf_file.c:222-224) and `GET /1/control/config` returns it, so the running config
   can be compared with the file. `PATCH /1/control/config` reloads synchronously and
   returns 200 (ngx_control.c:984-1023).
4. The sidecar sees `..data` change and its PATCH gets 200; `web` answers with the new config
   without anyone touching nginx.
5. A misspelled directive: `nginx -s reload` parses the whole config before it signals
   (ngx_init_cycle returns for the signaller only after ngx_conf_parse and the core
   modules' init_conf, ngx_cycle.c:316), so it exits 1 with the emerg and sends nothing.
   PATCH gets 422 with the same emerg. Both pods keep answering with the old config.
6. A certificate path that does not exist: ssl_certificate files are loaded while the http
   block is parsed (ngx_http_ssl_merge_srv_conf -> ngx_ssl_certificates,
   ngx_http_ssl_module.c:832), so the signaller fails too: exit 1. PATCH: 422.
   (ops-03 inferred the opposite for certificates; this checks it.)
7. An access_log in a directory that does not exist: log files are opened after the
   signaller has returned (ngx_cycle.c:365-399), so `nginx -s reload` exits 0, and the
   master's reload fails with "open() ... failed" in the error log. PATCH: 422 with that
   line. Old config keeps serving.
8. After the failed reload the file on disk is the bad config while nginx runs the old one.
   If the nginx container restarts (here: `nginx -s stop`), nginx starts from the file and
   fails, so the container keeps failing until the ConfigMap is fixed.
9. A good config after the failures: the sidecar's PATCH gets 200 and `web` answers with it.
