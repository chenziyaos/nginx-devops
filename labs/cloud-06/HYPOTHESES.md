# cloud-06 hypotheses (from the source of nginx 1.31.10, nginx-prometheus-exporter 1.5.3, nginx-otel 0.1.2 and the containerd configuration of the kind node)

Pod edge runs nginx (JSON access log on stdout, stub_status on 127.0.0.1:8080, control API on
a unix socket) and nginx-prometheus-exporter as a sidecar; edge proxies to the Pod app.

1. The exporter turns the seven stub_status numbers into accepted, handled and requests as
   counters and active, reading, writing, waiting as gauges, plus nginx_up
   (collector/nginx.go:26-32, 64-77): 3 counters and 5 gauges.
2. Every scrape of /metrics makes one GET /stub_status (collector/nginx.go:53), and
   ngx_stat_requests is incremented for every request, that one included: 10 requests
   between two scrapes add 11.
3. The counters live in the shared memory ngx_event_module_init maps once, when
   ngx_accept_mutex_ptr is still NULL (ngx_event.c:540-542, 566-608): a reload keeps them,
   a new master (a container restart) starts from 0. After the restart the exporter's
   scrapes are the only requests: 2 after the wait for nginx_up and one more read.
4. nginx writes the access log to /dev/stdout; containerd splits a line longer than
   max_container_log_line_size (16384 on the kind node) into a partial record (P) and the
   rest (F); kubectl logs joins them back into one valid JSON line.
5. With map $http_x_request_id the edge keeps an id that came with the request and uses
   $request_id (32 hex digits) otherwise; proxy_set_header passes it, the app logs the same.
6. Without a tracing module nginx does not touch traceparent: proxy_pass forwards client
   headers, the app receives the value the client sent.
7. With nginx-otel, `otel_trace on` and `otel_trace_context propagate`, the module reads
   traceparent (src/http_module.cpp:309-315), keeps its trace id and makes a new span id
   for nginx (src/trace_context.hpp:20-29); `$otel_parent_id` is the client's span id. It
   rewrites the request's traceparent with its own span id before proxy_pass
   (src/http_module.cpp:317-331, 383-391), so the app gets 00-<same trace>-<nginx span>-01.
   One span per request, kind Server, named after the location ("/"), with http.*
   attributes (src/http_module.cpp:408-460), exported to the collector over OTLP/gRPC.
8. Without a traceparent, nginx makes a new trace id, `$otel_parent_id` is empty, and the
   app gets nginx's trace id and span id.
9. After a reload, a worker that still serves a download is reported by
   GET /1/control/processes with "exiting": true next to the new worker; once the download
   ends only the new worker remains.
