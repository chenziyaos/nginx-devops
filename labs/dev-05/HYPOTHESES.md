# dev-05 hypotheses (from the source, before running)

1. ngx_event_process_init allocates cycle->connections, read_events and write_events with
   worker_connections (default 512) entries each: 512 * sizeof(ngx_connection_t) and twice
   512 * sizeof(ngx_event_t) bytes, printed by ev.c. The listening sockets and the channel
   are registered with EV_ADD|EV_ENABLE (fl:0005, level-triggered).
2. One request on a keepalive connection: the listening socket fires, ngx_event_accept adds
   client_header_timeout (60000) to the read event and registers the socket with
   EV_ADD|EV_ENABLE|EV_CLEAR (fl:0025, edge-triggered); the change is sent with the next
   kevent call ("changes: 1"), whose timeout is the nearest timer (60000). After the
   response the keepalive timer is 75000; EOF (fl:8025, EV_EOF) closes the connection and
   kevent waits forever again (-1).
3. With client_header_timeout 1s and a client that sends nothing, kevent returns 0 events
   after 1000 ms, ngx_event_expire_timers deletes the timer, sets timedout and calls the read
   handler, which logs "client timed out" and closes.
4. Two requests in one packet: after the first response ngx_http_set_keepalive sees the rest
   of the buffer, logs "pipelined request" and posts the read event to ngx_posted_events; it
   runs at the end of the same ngx_process_events_and_timers call ("posted event"), without
   another kevent wait. Revised after the first run: the second request has
   "Connection: close", so the connection then waits in lingering close (5000 ms timer,
   lingering_timeout) before closing; the script does not depend on that.
5. ngx_signal_worker_processes writes NGX_CMD_REOPEN (5) to the channel for USR1; the worker's
   channel handler logs "channel command: 5". kill() is used only if the write fails.
6. With "listen ... reuseport" and 4 workers, ngx_clone_listening makes 4 sockets for that
   address in the master; a listener without reuseport has one.
7. With accept_mutex on and 2 workers, ngx_event_process_init does not register the listening
   socket; the worker that wins ngx_trylock_accept_mutex adds it and keeps the mutex while
   it waits in kevent (NGX_POST_EVENTS, unlocked after ngx_process_events), so it waits
   forever (-1) when idle; the other fails and waits at most accept_mutex_delay (500 ms).
   Revised after the first run: the first version counted "kevent set event: 5" as a
   registration at startup; that line comes from ngx_enable_accept_events in the holder.
   Revised after repeated runs: one run in six showed a worker with both -1 and 500, because
   the mutex changed hands while the three requests arrived; the script now compares the last
   attempt and the last wait of each worker after the server is idle again.
