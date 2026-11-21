# dev-07 hypotheses (from the source, before running)

1. ngx_http_rewrite compiles every rewrite into regex_start, the copy codes of the replacement
   (copy "/new/", copy_capture $1), regex_end, all in the location's one code array; "last",
   "break", "redirect" and "permanent" add a NULL code (stop) after regex_end. In /chain/ the
   second rewrite has "last", so the third rewrite sits after a stop and never runs. A
   replacement that ends with "?" has no add_args. Code sizes on arm64: regex_start 72 bytes,
   copy 16 bytes plus the text rounded up to 8.
2. "set $b "$a-$uri"" is complex_value, copy_var $a, copy "-", copy_var $uri,
   complex_value_end, set_var $b. "if ($arg_mode = deny)" is push_var, push_value, equal, if;
   the body (return 403) is compiled into the same array and if.next jumps over it. A regex
   condition is push_var plus regex_start with "test".
3. Flags: no flag continues with the next directive and the location is chosen for the new URI
   only when the rewrite is at server level (before FIND_CONFIG); last sets uri_changed, so
   post_rewrite searches the location again; break clears uri_changed and keeps the location;
   an http:// replacement or permanent sets a status and a Location header.
4. The replacement's length is computed first (code->lengths, or code->size plus the capture
   lengths when there are no variables), then one buffer of that size is filled by the copy
   codes. add_args appends "&" and the original arguments.
5. The script engine is a stack: push_value/push_var push, equal pops two and pushes the result,
   if pops one. The debug log shows "http script value", "http script var", "http script equal:
   no", "http script if: false".
6. A variable created by set and never assigned on this path is empty; the rewrite module's
   get handler logs "using uninitialized "c" variable" (uninitialized_variable_warn on).
7. Caching: $uri is NOCACHEABLE, so after "rewrite ^ /flushed" (no flag) a later set reads the
   new URI. $sent_http_content_type is cacheable: read in the rewrite phase it is not found
   (no response header yet), and the access log, which uses ngx_http_get_indexed_variable,
   prints "-" for that request.
8. cmcf->variables holds only the variables used by this configuration (by set, return,
   log_format, modules), each with the flags of the definition it resolved to. set on $uri
   (not CHANGEABLE) fails with "the duplicate "uri" variable".
