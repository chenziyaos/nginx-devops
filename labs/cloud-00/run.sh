# cloud-00: smoke test of the cloud lab environment: the lab image, a Deployment behind a
# Service, a request from a client pod. Expected values come from HYPOTHESES.md.
. "$(dirname "$0")/../cloud-lib.sh"

conf web-conf conf/nginx.conf
apply k8s/web.yaml
k rollout status deploy/web --timeout=180s > /dev/null
client
web=$(pods app=web)

step "the lab image"
kx "$web" nginx -v 2>&1
kx "$web" nginx -V 2>&1 | tr ' ' '\n' | grep -E '^--(with-control-api|user=|conf-path=)'
# the stop signal is image metadata, read from the copy docker built
echo "STOPSIGNAL $(docker image inspect "$IMAGE" --format '{{.Config.StopSignal}}')"
expect "the pod runs nginx 1.31.10 with the control API compiled in, stopped by SIGQUIT" \
    "$(kx "$web" nginx -V 2>&1 | grep -m1 -o 'nginx/[0-9.]*') $(kx "$web" nginx -V 2>&1 | grep -c -- '--with-control-api') $(docker image inspect "$IMAGE" --format '{{.Config.StopSignal}}')" \
    "nginx/1.31.10 1 SIGQUIT"

step "processes in the pod"
# PID 1 is the master; the worker pids vary, so print user and command only
kx "$web" ps -eo pid=,user=,args= | awk '$3 == "nginx:" { print ($1 == 1 ? "pid 1" : "pid N"), $2, $3, $4, $5 }'
expect "the master is PID 1 and runs as root, the two workers run as nginx" \
    "$(kx "$web" ps -o user=,args= -p 1 | tr -s ' ') $(kx "$web" ps -eo user=,args= | grep -c '^nginx *nginx: worker')" \
    "root nginx: master process nginx -g daemon off; 2"

step "a request through the Service"
kx client curl -s "http://web.$NS.svc.cluster.local/" | sed "s/^$web /POD /"
expect "the Service name resolves and the response comes from the web pod" \
    "$(kx client curl -s "http://web.$NS.svc.cluster.local/")" "$web 1.31.10"
