# ops-03 hypotheses (from the source, before running)

1. The master starts worker_processes workers (ngx_start_worker_processes); "auto" is the
   number of online CPUs; proxy_cache_path adds a cache manager and a cache loader.
2. HUP: the master runs ngx_init_cycle with the new config; on success it starts new workers
   (NGX_PROCESS_JUST_RESPAWN) and sends QUIT to the old ones
   (ngx_master_process_cycle, ngx_process_cycle.c). An old worker closes its listening
   sockets and idle connections and exits when its last request is done.
3. On failure ngx_init_cycle returns NULL, the master logs the error and keeps the old cycle.
   `nginx -s reload` parses the config in the signaller first, so a broken config never
   reaches the master that way; kill -HUP does.
4. worker_shutdown_timeout is read from the cycle the exiting worker runs
   (ngx_set_shutdown_timer(cycle) in the worker), so it must be in the old config.
5. TERM: workers exit at once, connections are cut. QUIT: listening sockets closed,
   in-flight requests finish.
6. USR1: the master and workers reopen their log files (ngx_reopen_files); until then the
   workers keep writing to the renamed file.
7. A worker killed by a signal is respawned (ngx_reap_children, respawn flag).
8. USR2: the pid file is renamed to nginx.pid.oldbin and the binary is executed as a child of
   the old master with the listening sockets inherited (ngx_exec_new_binary). WINCH stops the
   old workers, QUIT ends the old master.
9. Control API (1.31.5, --with-control-api, -l addr): GET /1/nginx, /1/control/processes,
   PATCH /1/control/config runs ngx_init_cycle in the master and returns the captured log
   lines with 422 on failure (ngx_control_reload_config).
