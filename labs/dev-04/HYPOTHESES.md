# dev-04 hypotheses (from the source, before running)

1. ngx_conf_handler walks cycle->modules[] and each module's commands[] linearly; the first
   module whose type matches cf->module_type and whose command type has the bit of the
   current context (cf->cmd_type) takes the directive. "server" is in the commands of
   ngx_http_core_module, ngx_http_upstream_module, ngx_stream_core_module and
   ngx_stream_upstream_module, "listen" in the http and stream core modules.
2. ngx_conf_read_token: "#" starts a comment only where a new word starts, so a#b is one
   word; backslash escapes \n \t \r are expanded in any word (quoted or not); after "$" a
   "{" does not end the word (${host}); otherwise "{" ends the word, so "location /brace{"
   works without a space.
3. Errors and where they come from: the tokenizer ("unexpected "b"", "unexpected "}"",
   "unexpected end of file, expecting "}""), ngx_conf_handler ("unknown directive", "is not
   allowed here", "invalid number of arguments", "is not terminated by ";""), the set
   handler ("is duplicate"). All carry file:line. An unknown variable is found by
   ngx_http_variables_init_vars after the whole http{} block, so it has no file:line.
4. -g is ngx_conf_param, parsed by ngx_init_cycle before the configuration file, in the main
   context: a block is rejected, a missing ";" is "unexpected end of parameter", and a
   directive given in -g and in the file is reported as duplicate at the file's line.
5. ngx_http_block creates main/srv/loc arrays of ngx_http_max_module slots; server{} reuses
   main_conf and creates its own srv_conf and loc_conf; location{} reuses main and srv.
   ngx_http_merge_servers merges each server with http{} and each location with its
   parent (the server's loc_conf or the enclosing location): /a 5m, /a/b 5m from /a, /c,
   = /exact and ~ \.php$ 2m from http{}, server b and its / 1m.
   1 http + 2 server + 6 location contexts = 9 loc_conf arrays.
6. On reload ngx_init_cycle gives a new listening entry the fd of the old one with the same
   address (ngx_cmp_sockaddr), closes the old sockets nobody kept, and opens new ones:
   19082 keeps its fd, 19083 disappears, 19084 is new.
