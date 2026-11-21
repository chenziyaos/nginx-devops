# ops-04 hypotheses (from the source, before running)

1. Exact server_name first, then the longest "*.x" wildcard, then "x.*", then regex in config
   order (ngx_hash_find_combined, src/core/ngx_hash.c; ngx_http_find_virtual_server,
   src/http/ngx_http_request.c:2558). Order in the file does not matter except among regexes.
2. Host is lowercased and a trailing dot dropped before lookup; "a b" and "a..b" give 400
   (ngx_http_validate_host).
3. No match, or no Host: the default server of the address, which is the first server listed
   unless one has default_server (src/http/ngx_http.c:1365-1375, 1499).
4. Location: = on an exact URI stops; the longest prefix decides noregex; regexes in order;
   then predicates; else the longest prefix (ngx_http_core_find_location, :1446).
5. A ^~ on a shorter prefix does not help when a longer plain prefix matches.
6. On darwin NGX_HAVE_CASELESS_FILESYSTEM makes prefix comparison caseless.
7. Predicate true = value not empty and not "0" (:1515); "00" and "no" are true.
8. try_files: all arguments but the last are tested, the last is a URI, @name or =code.
   WRONG at first: I expected /docs to be served via "$uri/" with 200. The parser strips the
   trailing slash (ngx_http_try_files_module.c, test_dir), so the URI stays /docs and the static
   module answers 301 to /docs/. The lab checks the corrected claim.
9. alias replaces the location prefix: location /img + alias data/files/ maps /img../x to
   data/files/../x (ngx_http_map_uri_to_path, r->uri.data + alias).
10. return runs in REWRITE, before ACCESS: deny all does not stop it.
