# ops-12 hypotheses (from the source, before running)

1. A stream proxy copies bytes both ways and logs one line when the session ends.
   $bytes_received is what the client sent, $bytes_sent what it got; for a plain proxy
   $upstream_bytes_sent = $bytes_received and $upstream_bytes_received = $bytes_sent.
   $status is 200 for a normal end.
2. Passive checks (ngx_stream_upstream_free_round_robin_peer): a refused connect marks the
   peer failed (fails++, checked = now, effective_weight -= weight / max_fails), logs
   "upstream server temporarily disabled" when fails reaches max_fails, and the session
   moves to the next peer, so $upstream_addr lists both. While
   now - checked <= fail_timeout (whole seconds) the peer is skipped. After that it is
   eligible again, but its effective_weight was cut to 0 and grows by 1 per selection, so
   with two peers of weight 1 the smooth round robin picks the live peer twice before it
   tries the failed one again: live, live, dead -> live.
3. UDP: proxy_responses defaults to NGX_MAX_INT32_VALUE, so a UDP session waits for more
   datagrams until proxy_timeout; with "proxy_responses 1" it ends after the first reply,
   and the log line is written at once.
4. ssl_preread reads the ClientHello (MSG_PEEK on kqueue / epoll with EPOLLRDHUP, so the
   bytes stay in the socket) and sets $ssl_preread_server_name and
   $ssl_preread_protocol. A first byte other than 0x16 is "not a handshake": the variables
   are empty and the session goes on, so a map on the name can send plain TCP elsewhere.
5. Since 1.25.5 the preread name also selects a stream virtual server
   (ngx_stream_find_virtual_server) among the servers that share the listen socket; a
   name that matches no server_name stays in the default server. The access phase runs
   before preread, so "deny all" in the server{} that preread selects has no effect.
6. On a "listen ... ssl" port the SNI name selects the virtual server, and with it the
   certificate.
7. pass hands the accepted connection to another listening socket of the same nginx: no
   new TCP connection, so the target sees the client's own port; proxy_pass makes a new
   connection, so the target sees nginx's port. Only the target session writes a log
   line. A pass to an address no listen socket matches logs "port not found" and ends
   the session with status 200 (NGX_STREAM_OK).
8. proxy_protocol on / v2 (v2 since 1.31.4) sends a PROXY header before the data; a
   "listen ... proxy_protocol" server reads the client's address into
   $proxy_protocol_addr / $proxy_protocol_port, while $remote_port is nginx's. A
   connection without the header gets "broken header" and status 400.
