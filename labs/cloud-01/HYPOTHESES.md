# cloud-01 hypotheses (from the source, before running)

1. `worker_processes auto` is ngx_ncpu (src/core/nginx.c:1637-1639), which on Linux is
   sysconf(_SC_NPROCESSORS_ONLN) (src/os/unix/ngx_posix_init.c:61-65): the CPUs online on
   the node. A CPU limit (CFS quota) does not change it, so a pod limited to 1 CPU on an
   8-CPU node starts 8 workers.
2. glibc answers _SC_NPROCESSORS_ONLN from /sys/devices/system/cpu/online, not from the
   process's affinity mask, so starting nginx under `taskset -c 0` gives the same number.
3. `-g "worker_processes N;"` is parsed before the config file; with a config that does not
   set worker_processes, a downward-API limits.cpu of 2 gives exactly 2 workers.
4. Deleting a pod makes the kubelet send the image's STOPSIGNAL (SIGQUIT). The master
   relays QUIT, workers close their listening sockets and idle connections and finish the
   rest (ngx_process_cycle.c:763-769): an in-flight 5 s download completes.
5. SIGTERM sets ngx_terminate; workers exit without finishing requests: the download is cut.
   Kubernetes 1.37 cannot change the stop signal per pod by default: the
   ContainerStopSignals feature gate is alpha and off.
6. With terminationGracePeriodSeconds 2 the kubelet sends SIGKILL after 2 s: the download
   is cut about 2 s after the deletion. worker_shutdown_timeout 1s (ngx_set_shutdown_timer)
   makes nginx itself close the connection after 1 s, earlier.
7. QUIT closes the listening socket at once (master and workers), so right after the
   deletion a new connection to the pod IP is refused, while the EndpointSlice already
   marks the endpoint terminating. With a 5 s preStop sleep the signal is delayed and the
   pod still answers during the sleep.
8. A rolling restart under load therefore loses requests sent to the old pods in the window
   between the signal and the moment kube-proxy stops routing to them; with the preStop
   sleep none are lost.
9. As uid 101 on a read-only root filesystem nginx needs three writable places: the
   *_temp directories under /var/cache/nginx (ngx_create_paths), the pid file in /run,
   and nothing for the logs, which are symlinks to stdout/stderr. Port 80 can be bound as
   non-root because the runtime sets net.ipv4.ip_unprivileged_port_start to 0 in the pod.
