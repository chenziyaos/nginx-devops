# ops-11 hypotheses (from the source, before running)

1. Default log escaping (ngx_http_log_escape) writes '"', '\', bytes below 0x20, 0x7F and
   every byte from 0x80 up as \xHH, so UTF-8 text becomes \xC3\xA9. escape=json
   (ngx_escape_json) writes \" \\ and , and passes bytes from 0x80 up unchanged.
   escape=none writes the bytes as they are.
2. $bytes_sent = header bytes + $body_bytes_sent.
3. $upstream_header_time is the time to the response header, $upstream_response_time to
   the end of the response, $request_time from the first byte read from the client to the
   log write. A backend that sends its body slowly gives a small header time and a large
   response time; a backend that delays the header (limit_req delay) gives a large header
   time. connect <= header <= response <= request time.
4. With two attempts, $upstream_addr, $upstream_status and $upstream_response_time list one
   value per attempt separated by ", ".
5. access_log ... if=$var skips the line when $var is "" or "0".
6. access_log ... buffer=32k flush=1s keeps lines in memory until the buffer fills or the
   flush timer (1 s after the first buffered line) fires.
7. A missing file logs "open() ... failed (2: No such file or directory)" at error level;
   log_not_found off suppresses it.
8. stub_status: accepts = handled when no connection was dropped; requests grows by one
   per request, accepts by one per connection; Writing includes the status request itself.
9. After mv access.log, nginx keeps writing to the renamed file (same fd) until USR1 makes
   the master and workers reopen the path, which creates a new access.log.
10. json_set $v $source path (1.31.5) extracts one value from a JSON variable; invalid JSON
    or a missing path leaves the variable not found, logged as "-".
