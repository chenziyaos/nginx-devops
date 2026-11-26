# cloud-03 hypotheses (from the source and the specs, before running)

Versions: NGINX Gateway Fabric 2.9.1 (tag v2.9.1), Gateway API v1.7.0 CRDs,
ingress2gateway v1.2.0. NGF paths are relative to its repository.

1. A Gateway of class `nginx` makes NGF provision a Deployment and a Service named
   `<gateway>-nginx` in the Gateway's namespace. The pod runs nginx 1.31.10 (the NGF 2.9.1
   data plane image) and nginx-agent in one container; the agent receives the config from
   the control plane and reloads nginx with SIGHUP, so the error log shows
   "signal 1 (SIGHUP) received from <agent pid>". `worker_processes auto` (NGF
   main.conf) starts one worker per online CPU of the node (cloud-01).
2. Ingress annotations are a map of strings; the API server checks no key or value, so a
   misspelled annotation is stored. An HTTPRoute is a CRD with a structural schema:
   kubectl's strict field validation rejects an unknown field ("strict decoding error:
   unknown field") and the CRD enum rejects an unknown path type ("Unsupported value").
3. An HTTPRoute becomes nginx config like this (NGF internal/controller/nginx/config):
   - PathPrefix /api gives `location /api/` and `location = /api` (servers.go);
   - each backendRef is an upstream `<ns>_<svc>_<port>` whose servers are the pod IPs from
     the EndpointSlices, not the ClusterIP, with `random two least_conn` (upstreams.go:28)
     and a zone;
   - two weighted backends in one rule become `split_clients $request_id` with the
     percentages (split_clients_template.go:5);
   - a backendRef to a missing Service sets ResolvedRefs=False/BackendNotFound in the
     route status and routes to the upstream `invalid-backend-ref`, a unix socket
     server that returns 500.
4. split_clients hashes $request_id, which is random per request, so 1000 requests split
   roughly 80/20; v2's share stays between 14 % and 26 % (about 5 standard deviations).
5. A match with a header is checked by njs: the external location runs
   `js_content httpmatches.redirect`, which looks up the matches of that location in
   matches.json and returns 404 if none fits (httpmatches.js:40, :62). Locations are built
   per path (createLocations, servers.go:532), so the rules registered under /api are only
   the ones whose path is /api: a request to /api/x without the header gets 404 even though
   another rule has PathPrefix /. The Gateway API spec would send it to the / rule.
   Adding PathPrefix /api without a header to the / rule registers a second match
   (`"any":true`) under /api, and the request reaches it.
6. NGF with open source nginx has no API to change upstream servers: UpdateUpstreamServers
   returns early unless NGINX Plus is used (nginx/agent/agent.go:132-140). So a route
   change and an endpoint change both rewrite the files and reload: one more SIGHUP, the
   master PID stays, every worker PID is new. The generated config sets no
   worker_shutdown_timeout, so an old worker keeps serving a download in flight
   ("worker process is shutting down") until it is done, and the download completes.
7. ingress2gateway v1.2.0 with the ingress-nginx provider:
   - canary + canary-weight 20 becomes backend weights 20/80 in one rule;
   - enable-cors becomes a CORS filter with ingress-nginx's defaults;
   - use-regex makes every path of that host a RegularExpression match with a `(?i)`
     prefix, because ingress-nginx's regex locations are case-insensitive;
   - proxy-read-timeout 30 becomes timeouts.request = max(connect, read, send) x 10
     = 5m0s (common_emitter/emitter.go:33, :127);
   - rewrite-target with a capture group, limit-rps, configuration-snippet and
     proxy-body-size are reported as warnings and dropped; the exit code is still 0.
8. NGF validates regex paths with `/[^\s{};]*` (validation/common.go:15): `(?i)/api...`
   does not start with /, so every rule is invalid, the route gets
   Accepted=False/UnsupportedValue and requests get 404. With the paths changed to
   PathPrefix the route is accepted, but NGF does not implement HTTPRoute timeouts: the
   Accepted condition carries reason UnsupportedField and lists the ignored timeouts.
   The CORS filter is applied: a request with Origin gets Access-Control-Allow-Origin.
